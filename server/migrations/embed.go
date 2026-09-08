// Package migrations embeds the SQL migration files so the server binary is
// self-contained. Files are applied by internal/platform/database in filename
// order (0001_..., 0002_...).
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
