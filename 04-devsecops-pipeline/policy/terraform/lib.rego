# Helpers over `terraform show -json <plan>` output.
package terraform.lib

import rego.v1

# Every resource being created or updated (deletes can't introduce a misconfiguration).
changes contains rc if {
	some rc in input.resource_changes
	some action in rc.change.actions
	action in {"create", "update"}
}

after(rc) := rc.change.after

of_type(t) := {rc | some rc in changes; rc.type == t}
