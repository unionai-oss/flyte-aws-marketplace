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

Usage: describe-entity.py '<describe-entity json>' [<ami-id>]
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


def _ami_ids(node, acc):
    """Every AmiId anywhere under this node."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "AmiId" and isinstance(v, str):
                acc.add(v)
            else:
                _ami_ids(v, acc)
    elif isinstance(node, list):
        for item in node:
            _ami_ids(item, acc)
    return acc


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


def main():
    entity = json.loads(sys.argv[1])
    ami_id = sys.argv[2] if len(sys.argv) > 2 else ""

    doc = _details(entity)
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
        if match:
            result["target_option_id"] = match["option_id"]
            if match is not options[-1]:
                result["note"] = ("the AMI is on a version that is not the last one listed; "
                                  "check entity_identifier points at that version")
        elif len(options) == 1:
            result["target_option_id"] = options[0]["option_id"]
            result["note"] = ("the AMI was not found on a CloudFormation delivery option, "
                              "but there is only one, so that is the target")
        else:
            result["resolution"] = ("the AMI is already published, so a new version would be "
                                    "rejected, but it is not on a CloudFormation delivery "
                                    "option that could be updated instead")
    elif not published:
        if not options:
            # Nothing published at all, so there is nothing that could collide.
            result["resolution"] = "add"
        else:
            # Never fall back to "add": if the AMI IS already on a version and we
            # simply could not see it, add is rejected as a duplicate.
            result["resolution"] = ("DescribeEntity returned no AMI ids, so whether this AMI "
                                    "is already published cannot be determined")
    else:
        result["resolution"] = "add"

    print(json.dumps(result))


if __name__ == "__main__":
    main()
