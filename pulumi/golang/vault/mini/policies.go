// policies.go
package main

import (
	_ "embed"
	"fmt"
)

//go:embed magistrate.hcl
var Magistrate string

//go:embed template-read.hcl
var TemplateRead string

//go:embed template-admin.hcl
var TemplateAdmin string

func FormatTemplateRead(group string) string {
	return fmt.Sprintf(TemplateRead, group, group)
}

func FormatTemplateAdmin(group string) string {
	return fmt.Sprintf(TemplateAdmin, group, group)
}
