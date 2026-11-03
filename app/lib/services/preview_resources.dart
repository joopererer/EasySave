import '../core/media_request.dart';

List<MediaRequestResource> previewImageCandidates(
  List<MediaRequestResource> resources,
  String? url,
) {
  if (url == null || url.isEmpty) return const [];
  final primary = resources
      .where(
        (resource) =>
            resource.url == url &&
            {
              MediaResourceRole.image,
              MediaResourceRole.poster,
            }.contains(resource.role),
      )
      .firstOrNull;
  if (primary == null) return const [];
  return [
    primary,
    ...resources.where(
      (resource) =>
          resource.role == MediaResourceRole.fallback &&
          resource.fallbackFor == primary.role &&
          resource.url != primary.url,
    ),
  ];
}
