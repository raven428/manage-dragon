// main.go
package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"

	"github.com/pulumi/pulumi-vault/sdk/v7/go/vault"
	"github.com/pulumi/pulumi-vault/sdk/v7/go/vault/generic"
	"github.com/pulumi/pulumi-vault/sdk/v7/go/vault/identity"
	"github.com/pulumi/pulumi-vault/sdk/v7/go/vault/kv"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

const (
	charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}|;:,.<>?/"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")
		stack := ctx.Stack()

		userpassData := VaultGet(
			"v1/sys/auth",
			[]string{"data"},
			func(k string, v map[string]interface{}) bool {
				vType, _ := v["type"].(string)
				return vType == "userpass" && k == "userpass/"
			},
		)

		var opts []pulumi.ResourceOption
		if stack != "auth" || userpassData != nil {
			opts = []pulumi.ResourceOption{pulumi.Import(pulumi.ID("userpass"))}
		}

		userpassAuth, err := vault.NewAuthBackend(ctx, "userpass", &vault.AuthBackendArgs{
			Type: pulumi.String("userpass"),
		}, opts...)
		if err != nil {
			return err
		}

		if stack == "auth" {
			ctx.Export("auth backend", userpassAuth.ID())
			return nil
		}

		var groups []string
		cfg.RequireObject("groups", &groups)

		for _, g := range groups {
			if err := EnsureGroup(ctx, fmt.Sprintf("read-%s", g), FormatTemplateRead(g), nil); err != nil {
				return err
			}
			if err := EnsureGroup(ctx, fmt.Sprintf("admin-%s", g), FormatTemplateAdmin(g), nil); err != nil {
				return err
			}
		}

		auditData := VaultGet(
			"v1/sys/audit",
			[]string{"data"},
			func(k string, v map[string]interface{}) bool {
				vType, _ := v["type"].(string)
				return vType == "syslog" && k == "syslog/"
			},
		)

		var auditOpts []pulumi.ResourceOption
		if auditData != nil {
			auditOpts = []pulumi.ResourceOption{pulumi.Import(pulumi.ID("syslog"))}
		}

		_, err = vault.NewAudit(ctx, "syslog", &vault.AuditArgs{
			Type: pulumi.String("syslog"),
			Options: pulumi.StringMap{
				"tag":      pulumi.String("vaudit"),
				"facility": pulumi.String("AUTH"),
			},
		}, auditOpts...)
		if err != nil {
			return err
		}

		var admins []string
		cfg.RequireObject("admins", &admins)

		adminEntities := make([]pulumi.IDOutput, 0, len(admins))

		for _, admin := range admins {
			password := generatePassword()

			var userOpts []pulumi.ResourceOption
			_, getUserErr := generic.LookupSecret(ctx, &generic.LookupSecretArgs{
				Path: fmt.Sprintf("auth/userpass/users/%s", admin),
			})
			if getUserErr != nil {
				ctx.Log.Info(fmt.Sprintf("No user [%s] found…", admin), nil)
			} else {
				userOpts = []pulumi.ResourceOption{pulumi.IgnoreChanges([]string{"dataJson"})}
			}

			userOpts = append(userOpts, pulumi.DependsOn([]pulumi.Resource{userpassAuth}))

			dataMap := map[string]interface{}{
				"password": password,
			}
			dataJSON, _ := json.Marshal(dataMap)

			_, err = generic.NewSecret(ctx, fmt.Sprintf("user-password-%s", admin), &generic.SecretArgs{
				Path:     pulumi.String(fmt.Sprintf("auth/userpass/users/%s", admin)),
				DataJson: pulumi.String(string(dataJSON)),
			}, userOpts...)
			if err != nil {
				return err
			}

			var entityOpts []pulumi.ResourceOption
			existingEntity, getEntityErr := identity.LookupEntity(ctx, &identity.LookupEntityArgs{
				EntityName: pulumi.StringRef(fmt.Sprintf("ent-%s", admin)),
			})
			if getEntityErr != nil {
				ctx.Log.Info(fmt.Sprintf("No entity [ent-%s] found…", admin), nil)
			} else {
				ctx.Log.Info(fmt.Sprintf("Entity [ent-%s] id [%s] catchup…", admin, existingEntity.EntityId), nil)
				entityOpts = []pulumi.ResourceOption{pulumi.Import(pulumi.ID(existingEntity.EntityId))}
			}

			entity, err := identity.NewEntity(ctx, fmt.Sprintf("ent-%s", admin), &identity.EntityArgs{
				Name: pulumi.String(fmt.Sprintf("ent-%s", admin)),
				Metadata: pulumi.StringMap{
					"role": pulumi.String("overlord"),
				},
			}, entityOpts...)
			if err != nil {
				return err
			}

			adminEntities = append(adminEntities, entity.ID())

			var aliasOpts []pulumi.ResourceOption
			if existingEntity != nil {
				fullEntity, _ := identity.LookupEntity(ctx, &identity.LookupEntityArgs{
					EntityId: pulumi.StringRef(existingEntity.EntityId),
				})
				if fullEntity != nil {
					accessor, _ := userpassData["accessor"].(string)
					for _, alias := range fullEntity.Aliases {
						if alias.MountAccessor == accessor {
							ctx.Log.Info(fmt.Sprintf("Alias [%s] id [%s] catchup…", admin, alias.Id), nil)
							aliasOpts = []pulumi.ResourceOption{pulumi.Import(pulumi.ID(alias.Id))}
							break
						}
					}
				}
			}
			if len(aliasOpts) == 0 {
				ctx.Log.Info(fmt.Sprintf("No alias [%s] found…", admin), nil)
			}

			accessor, _ := userpassData["accessor"].(string)
			_, err = identity.NewEntityAlias(ctx, fmt.Sprintf("als-%s", admin), &identity.EntityAliasArgs{
				Name:          pulumi.String(admin),
				CanonicalId:   entity.ID(),
				MountAccessor: pulumi.String(accessor),
			}, aliasOpts...)
			if err != nil {
				return err
			}
		}

		if err := EnsureGroup(ctx, "magistrate", Magistrate, adminEntities); err != nil {
			return err
		}

		storageData := VaultGet(
			"v1/sys/mounts",
			[]string{"data"},
			func(k string, v map[string]interface{}) bool {
				vType, _ := v["type"].(string)
				return vType == "kv" && k == "depot/"
			},
		)

		var storageOpts []pulumi.ResourceOption
		if storageData != nil {
			storageOpts = []pulumi.ResourceOption{pulumi.Import(pulumi.ID("depot"))}
		}

		depotMount, err := vault.NewMount(ctx, "v2kv-depot-mount", &vault.MountArgs{
			Path: pulumi.String("depot"),
			Type: pulumi.String("kv"),
			Options: pulumi.StringMap{
				"version": pulumi.String("2"),
			},
		}, storageOpts...)
		if err != nil {
			return err
		}

		_, err = kv.NewSecretBackendV2(ctx, "v2kv-depot-config", &kv.SecretBackendV2Args{
			Mount:              pulumi.String("depot"),
			MaxVersions:        pulumi.Int(555),
			CasRequired:        pulumi.Bool(true),
			DeleteVersionAfter: pulumi.Int(0),
		}, pulumi.DependsOn([]pulumi.Resource{depotMount}))
		if err != nil {
			return err
		}

		return nil
	})
}

func generatePassword() string {
	length, _ := rand.Int(rand.Reader, big.NewInt(11))
	passLen := int(length.Int64()) + 44

	password := make([]byte, passLen)
	for i := 0; i < passLen; i++ {
		idx, _ := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		password[i] = charset[idx.Int64()]
	}
	return string(password)
}
