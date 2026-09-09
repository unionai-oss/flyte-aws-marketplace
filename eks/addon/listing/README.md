# Marketplace listing copy

The text the AWS Marketplace **Add new version** form asks for, kept here so it
is reviewed in PRs and submitted identically every time rather than retyped into
the portal. `scripts/submit-version.sh` reads these files and
`../metadata.yaml` to build the Catalog API change set.

| file | portal field | limit |
|---|---|---|
| `delivery-option-title.txt` | Delivery option title | — |
| `delivery-option-description.txt` | Delivery option description | 1,000 chars |
| `usage-instructions.txt` | Usage instructions | 4,000 chars |
| `release-notes.txt` | Release notes | 30,000 chars |

The **version title** is generated, not stored: `Flyte <flyteVersion> (add-on
<version>)` from `metadata.yaml`. Titles must be unique per version, and a
rejected submission still consumes one, so it always tracks the add-on version.

`submit-version.sh` enforces the character limits before submitting — the portal
form does too, but the Catalog API will happily accept an over-long string and
fail the change set asynchronously.
