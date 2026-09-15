#!/usr/bin/env python3
"""Read an AmiProduct DescribeEntity result and work out what submit-version.sh
should do with it.

Two jobs:

  1. Decide add-vs-update. AWS requires every VERSION of an AMI product to carry
     a distinct AMI id, so if the AMI we would submit is already on a version,
     "add" is not an available choice - it is rejected as a duplicate - and the
     only legal action is to update that version. This is a rule, not a guess.

  2. Find what UpdateDeliveryOptions has to address: the entity identifier (with
     its @version suffix) and the delivery option id.

The response is walked tolerantly rather than by a fixed path, because the exact
AmiProduct detail shape is not something we want to hard-code and silently break
on. Anything it cannot determine comes back as a reason string, never a default -
a change set aimed at the wrong version is worse than one that refuses to build.

Takes a PATH rather than the JSON itself: the response outgrew the 128 KB Linux
caps on a single argv entry once the listing carried three versions, each with a
long AvailableInstanceTypes list, and execve failed with "Argument list too long".
It only grows from here.

Usage: describe-entity.py <path-to-describe-entity.json> [<ami-id>]
"""
import json
import sys


def _details(entity):
    """The details payload, whether it arrives parsed or as a JSON string."""
    doc = entity.get("DetailsDocument")
    if doc is None and isinstance(entity.get("Details"), str):
        try:
            doc = json.loads(entity["Details"])
        except ValueError:
            doc = None
    return doc or {}


# DescribeEntity and the change-set schema spell the same thing differently:
# a version's AMI arrives as Sources[].Image here, and as
# TemplateSources[].AmiSource.AmiId there. Accept both - looking only for AmiId
# is what made a listing with three published versions read as empty.
AMI_KEYS = ("AmiId", "Image")


def _ami_ids(node, acc):
    """Every AMI id anywhere under this node, under either spelling."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in AMI_KEYS and isinstance(v, str) and v.startswith("ami-"):
                acc.add(v)
            else:
                _ami_ids(v, acc)
    elif isinstance(node, list):
        for item in node:
            _ami_ids(item, acc)
    return acc


def _is_cft(option):
    """Does this delivery option deliver a CloudFormation template?

    DescribeEntity labels it with a Type; the change-set schema instead nests
    DeploymentTemplateDeliveryOptionDetails. Recognise either.
    """
    if "DeploymentTemplateDeliveryOptionDetails" in (option.get("Details") or {}):
        return True
    label = " ".join(str(option.get(k, "")) for k in ("Type", "DeliveryOptionType"))
    return "cloudformation" in label.lower() or "template" in label.lower()


def _from_versions(versions):
    """The structured path: DetailsDocument.Versions[] as DescribeEntity returns it.

    The AMI sits at VERSION level (Sources[].Image), not inside the delivery
    option, so options inherit their version's AMI ids rather than being
    searched individually.
    """
    out = []
    for v in versions:
        if not isinstance(v, dict):
            continue
        amis = sorted(_ami_ids(v, set()))
        options = [o for o in (v.get("DeliveryOptions") or []) if isinstance(o, dict)]
        for o in options:
            out.append({
                "option_id": o.get("Id"),
                "version": v.get("VersionTitle") or v.get("Id"),
                "version_id": v.get("Id"),
                "type": o.get("Type") or o.get("DeliveryOptionType"),
                "is_cloudformation": _is_cft(o),
                "visibility": o.get("Visibility"),
                "ami_ids": amis,
            })
        if not options:
            # A version with no delivery options we can see still carries AMIs
            # that count against the duplicate rule.
            out.append({
                "option_id": None,
                "version": v.get("VersionTitle") or v.get("Id"),
                "version_id": v.get("Id"),
                "type": None,
                "is_cloudformation": False,
                "visibility": None,
                "ami_ids": amis,
            })
    return out


def _options(node, version, out):
    """Every CloudFormation delivery option, with the version it belongs to."""
    if isinstance(node, dict):
        here = node.get("VersionTitle") or node.get("Version") or version
        if isinstance(here, dict):
            here = here.get("VersionTitle") or version
        for opt in node.get("DeliveryOptions") or []:
            if not isinstance(opt, dict):
                continue
            details = opt.get("Details") or {}
            if "DeploymentTemplateDeliveryOptionDetails" not in details:
                continue
            out.append({
                "option_id": opt.get("Id"),
                "version": here,
                "visibility": opt.get("Visibility"),
                "ami_ids": sorted(_ami_ids(opt, set())),
            })
        for v in node.values():
            _options(v, here, out)
    elif isinstance(node, list):
        for item in node:
            _options(item, version, out)
    return out


def outline(node, depth=0, max_depth=4):
    """A compact shape of the response - keys and container types, no values.

    Printed so that a DetailsDocument we cannot parse is diagnosable from the CI
    log without dumping the whole (large) document.
    """
    if depth >= max_depth:
        return "..."
    if isinstance(node, dict):
        return {k: outline(v, depth + 1, max_depth) for k, v in list(node.items())[:25]}
    if isinstance(node, list):
        return [outline(node[0], depth + 1, max_depth), f"...x{len(node)}"] if node else []
    return type(node).__name__


def main():
    with open(sys.argv[1]) as fh:
        entity = json.load(fh)
    ami_id = sys.argv[2] if len(sys.argv) > 2 else ""

    doc = _details(entity)
    # Prefer the documented DescribeEntity shape; fall back to the tolerant walk
    # for anything that does not present a Versions[] list.
    versions = doc.get("Versions")
    if isinstance(versions, list) and versions:
        options = _from_versions(versions)
    else:
        options = _options(doc, None, [])

    # De-duplicate: the tolerant walk can reach the same option by two paths.
    seen, unique = set(), []
    for o in options:
        if o["option_id"] in seen:
            continue
        seen.add(o["option_id"])
        unique.append(o)
    options = unique

    result = {
        "entity_identifier": entity.get("EntityIdentifier") or entity.get("EntityArn"),
        "entity_keys": sorted(entity.keys()),
        "details_outline": outline(doc),
        "ami_id": ami_id,
        "options": options,
        "target_option_id": None,
        "resolution": None,
    }

    # The duplicate check spans EVERY AMI in the listing, not just the ones on
    # CloudFormation delivery options: AWS scopes "distinct AMI id" to the
    # product, so an AMI used by any other kind of delivery option collides too.
    # The update TARGET, though, can only ever be a CloudFormation option.
    published = sorted(_ami_ids(doc, set()))
    result["published_ami_ids"] = published
    match = next((o for o in options if ami_id and ami_id in o["ami_ids"]), None)

    if not ami_id:
        result["resolution"] = "no AMI id supplied to compare against"
    elif ami_id in published:
        # Already on the listing, so adding it again is not a choice that exists.
        result["resolution"] = "update"
        cft = [o for o in options
               if o.get("option_id") and o.get("is_cloudformation", True)
               and ami_id in o["ami_ids"]]
        if cft:
            match = cft[0]
        if match and match.get("option_id"):
            result["target_option_id"] = match["option_id"]
            if match is not options[-1]:
                result["note"] = ("the AMI is on a version that is not the last one listed; "
                                  "check entity_identifier points at that version")
        elif len([o for o in options if o.get("option_id")]) == 1:
            result["target_option_id"] = next(o["option_id"] for o in options if o.get("option_id"))
            result["note"] = ("the AMI was not found on a CloudFormation delivery option, "
                              "but there is only one, so that is the target")
        else:
            result["resolution"] = ("the AMI is already published, so a new version would be "
                                    "rejected, but it is not on a CloudFormation delivery "
                                    "option that could be updated instead")
    elif not published:
        # "Found no AMI ids" is NOT "the listing is empty" - the two are
        # indistinguishable from here, and guessing "add" on the second reading
        # is how this resolved to a guaranteed Duplicate AMI id rejection. Only
        # a positive list of published AMIs can justify "add", so refuse.
        result["resolution"] = ("DescribeEntity returned no AMI ids, so whether this AMI is "
                                "already published cannot be determined - see details_outline")
    else:
        result["resolution"] = "add"

    print(json.dumps(result))


if __name__ == "__main__":
    main()
