# Pods (a PodList from /api/v1/pods) -> the images to scan, one JSON object per line:
#   {"ref": what trivy pulls, "image": the reference the pod asked for}
# $exclude: namespaces left out (SafeZone's, whose operations is its own block).
# Init containers count: what runs is what is exposed. An image is scanned by the
# digest the node resolved (imageID), so a tag that moved is not scanned in its place.
[
  .items[]
  | select(.metadata.namespace as $ns | $exclude | index($ns) | not)
  | .status
  | ((.containerStatuses // []) + (.initContainerStatuses // []))[]
  | (.imageID // "" | sub("^docker-pullable://"; "")) as $id
  | if ($id | test("^[^@]+@sha256:[0-9a-f]{64}$"))
    then {ref: $id, image: .image}
    else {ref: .image, image: .image}
    end
]
| unique_by(.ref)
| .[]
