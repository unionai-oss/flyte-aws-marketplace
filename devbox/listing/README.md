# Marketplace listing copy

The text the AWS Marketplace **Add new version** form asks for, kept here so it
is reviewed in PRs and submitted identically every time rather than retyped into
the portal. `scripts/submit-version.sh` reads these files and `../versions.env`
to build the Catalog API change set.

| file | portal field | limit |
|---|---|---|
| `delivery-option-title.txt` | Delivery option title | 100 chars |
| `short-description.txt` | Short description | 1,000 chars |
| `long-description.txt` | Long description | 5,000 chars |
| `usage-instructions.txt` | Usage instructions | 4,000 chars |
| `release-notes.txt` | Release notes | 30,000 chars |

The **version title** is generated, not stored: `Flyte devbox <ami-id>`. Titles
must be unique across the product's entire history, and a *rejected* submission
still consumes one, so tying it to the AMI id makes it unique by construction
and tells a buyer which image they are getting. Override with `VERSION_TITLE=`
when resubmitting against the same AMI after a rejection.

**Keep the copy ASCII.** `submit-version.sh` rejects non-ASCII before submitting,
because AWS returns `INVALID_*` / "unsupported characters" *asynchronously*,
hours later, having already spent the version title. Em dashes and smart quotes
are the usual way they get in — they survive a paste from a doc and are
invisible in a diff. Write `-` and `"`.

The limits are enforced locally for the same reason: the Catalog API accepts an
over-long string and fails the change set later, rather than rejecting the call.
