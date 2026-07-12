// cspell:ignore nspawn podman nftables moreutils ansidem
package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	ci "github.com/megalomania428/go-lib-ci"
)

const (
	defaultPlatform   = "podman"
	defaultAnsibleVer = "11"
	defaultRegi       = "ghcr.io/raven428/container-images"
	defaultDistro     = "debian13"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func run(ctx context.Context) error {
	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve executable: %w", err)
	}
	if !strings.Contains(self, "go-build") {
		return fmt.Errorf(
			"must be run via `go run`, not as a compiled binary (%s)", self,
		)
	}
	platform := getenv("PLATFORM", defaultPlatform)
	ansibleVer := getenv("ANSIBLE_VER", defaultAnsibleVer)
	distro := getenv("DISTRO", defaultDistro)
	regi := getenv("REGI", defaultRegi)
	image := getenv("IMAGE", regi+"/systemd-"+distro+":latest")
	fmt.Printf("platform [%s] with [%s] ansible\n", platform, ansibleVer)
	ansibleDir, err := resolveAnsibleDir()
	if err != nil {
		return err
	}
	appImageBin, err := fetchAnsibleAppImage(ctx, ansibleVer)
	if err != nil {
		return fmt.Errorf("fetch ansible appimage: %w", err)
	}
	targetName, err := setupPlatform(ctx, platform, image, ansibleDir)
	if err != nil {
		return err
	}
	res, err := runDeploy(ctx, appImageBin, targetName, ansibleDir)
	// always clean up container regardless of deploy result
	if platform == "docker" || platform == "podman" {
		if rmErr := runCmd(ctx, platform, "rm", "-f", targetName); rmErr != nil {
			fmt.Fprintf(os.Stderr, "==> warn: %s rm -f %s: %v\n", platform, targetName, rmErr)
		}
	}
	if err != nil {
		return err
	}
	if res > 0 {
		return fmt.Errorf("changed=%d: ansible isn't idempotent", res)
	}
	return nil
}

// fetchAnsibleAppImage wraps ci.FetchGithubRelease for the ansible AppImage
// convention: repo raven428/container-images, asset ansible-<ver>-001.AppImage.
func fetchAnsibleAppImage(ctx context.Context, ver string) (string, error) {
	build := getenv("APPIMAGE_BUILD", "001")
	release := getenv("APPIMAGE_RELEASE", "")
	assetName := fmt.Sprintf("ansible-%s-%s.AppImage", ver, build)
	destDir := filepath.Join(os.Getenv("HOME"), "bin")
	path, err := ci.FetchGitHubRelease(ctx, ci.FetchOptions{
		Repo:               "raven428/container-images",
		Tag:                release,
		AssetName:          assetName,
		DestDir:            destDir,
		Token:              os.Getenv("GITHUB_TOKEN"),
		FallbackToExisting: true,
	})
	if err != nil {
		return "", err
	}
	return path, nil
}

func setupPlatform(
	ctx context.Context, platform, image, ansibleDir string,
) (string, error) {
	switch platform {
	case "nspawn":
		return setupNspawn(ctx, ansibleDir, image)
	case "docker":
		return setupContainer(ctx, platform, image, "dkr4ans")
	case "podman":
		return setupContainer(ctx, platform, image, "pdm4ans")
	default:
		return "", fmt.Errorf(
			"wrong [%s] platform, expected: nspawn|docker|podman", platform,
		)
	}
}

func setupNspawn(ctx context.Context, ansibleDir, image string) (string, error) {
	if err := ci.EnsurePackages(ctx, []string{
		"systemd-container", "nftables", "less", "moreutils",
	}, ci.EnsurePackagesOptions{}); err != nil {
		return "", fmt.Errorf("ensure packages: %w", err)
	}
	if err := runCmd(ctx, "sudo", "nft", "flush", "ruleset"); err != nil {
		return "", fmt.Errorf("nft flush ruleset: %w", err)
	}
	scriptPath := filepath.Join(ansibleDir, "..", "bin", "deploy-nspawn.sh")
	cmd := exec.CommandContext(ctx, "bash", scriptPath)
	cmd.Env = append(os.Environ(), "NSPAWN="+image)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("deploy-nspawn.sh: %w", err)
	}
	if err := runCmd(ctx, "sudo", "systemctl", "restart", "docker"); err != nil {
		return "", fmt.Errorf("restart docker: %w", err)
	}
	return "nsp4ans", nil
}

func setupContainer(
	ctx context.Context, platform, image, targetName string,
) (string, error) {
	if err := runCmd(ctx, platform, "pull", image); err != nil {
		return "", fmt.Errorf("%s pull %s: %w", platform, image, err)
	}
	local := "l.c/" + targetName + ":l"
	if err := runCmd(ctx, platform, "tag", image, local); err != nil {
		return "", fmt.Errorf("%s tag: %w", platform, err)
	}
	running, _ := cmdOutput(ctx, platform,
		"inspect", "--format", "{{.State.Running}}", targetName,
	)
	if strings.TrimSpace(running) != "true" {
		args := []string{
			"run", "-d", "--cap-add=NET_ADMIN", "--rm",
			"--hostname=" + targetName, "--name=" + targetName, local,
		}
		if err := runCmd(ctx, platform, args...); err != nil {
			return "", fmt.Errorf("%s run: %w", platform, err)
		}
	}
	return targetName, nil
}

func runDeploy(
	ctx context.Context, appImageBin, targetName, ansibleDir string,
) (int, error) {
	sshEnv := sshAgentEnv()
	galaxy := exec.CommandContext(
		ctx, appImageBin, "ansible-galaxy", "install", "-r", "requirements.yaml",
	)
	galaxy.Dir = ansibleDir
	galaxy.Stdout = os.Stdout
	galaxy.Stderr = os.Stderr
	galaxy.Env = append(os.Environ(), sshEnv...)
	if err := galaxy.Run(); err != nil {
		return 0, fmt.Errorf("ansible-galaxy: %w", err)
	}
	playbookArgs := []string{
		"ansible-playbook", "site.yaml", "--diff",
		"-i", "inventory", "-u", "root", "-l", targetName,
	}
	first := exec.CommandContext(ctx, appImageBin, playbookArgs...)
	first.Dir = ansibleDir
	first.Stdout = os.Stdout
	first.Stderr = os.Stderr
	first.Env = append(os.Environ(), sshEnv...)
	if err := first.Run(); err != nil {
		return 0, fmt.Errorf("ansible-playbook (first run): %w", err)
	}
	logFile, err := os.CreateTemp("", "ansidem*.log")
	if err != nil {
		return 0, fmt.Errorf("create log file: %w", err)
	}
	logPath := logFile.Name()
	logFile.Close()
	defer os.Remove(logPath)
	second := exec.CommandContext(ctx, appImageBin, playbookArgs...)
	second.Dir = ansibleDir
	second.Stdout = os.Stdout
	second.Stderr = os.Stderr
	second.Env = append(os.Environ(), append(sshEnv, "ANSIBLE_LOG_PATH="+logPath)...)
	if err := second.Run(); err != nil {
		return 0, fmt.Errorf("ansible-playbook (second run): %w", err)
	}
	changed, err := countChanged(logPath)
	if err != nil {
		return 0, fmt.Errorf("count changed: %w", err)
	}
	return changed, nil
}

// sshAgentEnv sources the agent env file written by deploy-nspawn.sh and
// returns SSH_AUTH_SOCK and SSH_AGENT_PID as "KEY=value" strings.
// Returns empty slice if the file does not exist.
func sshAgentEnv() []string {
	const envFile = "/tmp/ssh-agent-nspawn.env"
	if _, err := os.Stat(envFile); err != nil {
		return nil
	}
	var env []string
	for _, key := range []string{"SSH_AUTH_SOCK", "SSH_AGENT_PID"} {
		out, err := exec.Command(
			"bash", "-c", ". "+envFile+" >/dev/null 2>&1; printf '%s' \"$"+key+"\"",
		).Output()
		if err != nil || len(out) == 0 {
			continue
		}
		env = append(env, key+"="+string(out))
	}
	return env
}

var reChanged = regexp.MustCompile(`(?i)\bchanged=(\d+)\b`)

func countChanged(logPath string) (int, error) {
	f, err := os.Open(logPath)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	total := 0
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, "changed=") {
			continue
		}
		for _, m := range reChanged.FindAllStringSubmatch(line, -1) {
			n, _ := strconv.Atoi(m[1])
			total += n
		}
	}
	return total, scanner.Err()
}

func resolveAnsibleDir() (string, error) {
	// go run with working-directory=golang (GitHub Actions)
	abs, err := filepath.Abs(filepath.Join("..", "ansible"))
	if err != nil {
		return "", fmt.Errorf("resolve ansible dir: %w", err)
	}
	if st, err := os.Stat(abs); err != nil || !st.IsDir() {
		return "", fmt.Errorf("cannot locate ansible at [%s] directory", abs)
	}
	return abs, nil
}

func runCmd(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func cmdOutput(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).Output()
	return string(out), err
}

func main() {
	ctx, stop := signal.NotifyContext(
		context.Background(),
		syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT, syscall.SIGABRT,
	)
	err := run(ctx)
	stop()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
