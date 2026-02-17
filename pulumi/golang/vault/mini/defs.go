// defs.go
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/pulumi/pulumi-vault/sdk/v7/go/vault"
	"github.com/pulumi/pulumi-vault/sdk/v7/go/vault/identity"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func VaultGet(
	url string,
	path []string,
	expr func(string, map[string]interface{}) bool,
) map[string]interface{} {
	vaultAddr := os.Getenv("VAULT_ADDR")
	vaultToken := os.Getenv("VAULT_TOKEN")

	req, err := http.NewRequest("GET", fmt.Sprintf("%s/%s", vaultAddr, url), nil)
	if err != nil {
		return nil
	}

	req.Header.Set("X-Vault-Token", vaultToken)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil
	}

	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil
	}

	target := result
	for _, key := range path {
		if next, ok := target[key].(map[string]interface{}); ok {
			target = next
		} else {
			return nil
		}
	}

	if expr == nil {
		return nil
	}

	for k, v := range target {
		if vMap, ok := v.(map[string]interface{}); ok {
			if expr(k, vMap) {
				return vMap
			}
		}
	}

	return nil
}

func EnsureGroup(
	ctx *pulumi.Context,
	groupSuffix string,
	policyBody string,
	memberEntityIDs []pulumi.IDOutput,
) error {
	_, err := vault.NewPolicy(ctx, fmt.Sprintf("pol-%s", groupSuffix), &vault.PolicyArgs{
		Name:   pulumi.String(fmt.Sprintf("pol-%s", groupSuffix)),
		Policy: pulumi.String(policyBody),
	})
	if err != nil {
		return err
	}

	groupName := fmt.Sprintf("gr-%s", groupSuffix)

	var groupOpts []pulumi.ResourceOption
	existingGroup, getGroupErr := identity.LookupGroup(ctx, &identity.LookupGroupArgs{
		GroupName: pulumi.StringRef(groupName),
	})
	if getGroupErr != nil {
		ctx.Log.Info(fmt.Sprintf("No group [%s] found…", groupName), nil)
	} else {
		ctx.Log.Info(fmt.Sprintf("Group [%s] id [%s] catchup…", groupName, existingGroup.GroupId), nil)
		groupOpts = []pulumi.ResourceOption{pulumi.Import(pulumi.ID(existingGroup.GroupId))}
	}

	groupArgs := &identity.GroupArgs{
		Name: pulumi.String(groupName),
		Policies: pulumi.StringArray{
			pulumi.String(fmt.Sprintf("pol-%s", groupSuffix)),
		},
	}

	if memberEntityIDs != nil {
		idArray := make(pulumi.StringArray, len(memberEntityIDs))
		for i, id := range memberEntityIDs {
			idArray[i] = id.ToStringOutput().ApplyT(func(s string) string { return s }).(pulumi.StringOutput)
		}
		groupArgs.MemberEntityIds = idArray
	}

	_, err = identity.NewGroup(ctx, groupName, groupArgs, groupOpts...)
	return err
}
