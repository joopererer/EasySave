// Pure download helpers: filename building and per-item download targets.
// No browser APIs here so the logic stays unit-testable.

export type MediaKind = "image" | "video" | "live";

export interface MediaItemLike {
  type: MediaKind;
  url: string;
  videoUrl?: string;
}

export interface DownloadTarget {
  url: string;
  filename: string;
}

export interface FilenameContext {
  platform: string;
  author?: string;
  id: string;
}

/** Replace characters illegal in file names with underscores. */
export function sanitizeFilePart(value: string, fallback: string): string {
  const clean = value
    .replace(/[\u0000-\u001f\\/:*?"<>|]/g, "_")
    .replace(/^\.+/, "")
    .trim()
    .replace(/\.+$/, "");
  return clean || fallback;
}

function extensionFromPath(pathname: string): string | undefined {
  const base = pathname.split("/").pop() ?? "";
  const dot = base.lastIndexOf(".");
  if (dot < 0) return undefined;
  const ext = base.slice(dot + 1).toLowerCase();
  return /^[a-z0-9]{2,5}$/.test(ext) ? ext : undefined;
}

/** Guess a file extension from a media URL, with a type-based fallback. */
export function extensionFromUrl(url: string, type: MediaKind): string {
  try {
    const parsed = new URL(url);
    const ext = extensionFromPath(parsed.pathname);
    if (ext) return ext;
  } catch {
    // Fall through to the type default.
  }
  return type === "image" ? "jpg" : "mp4";
}

export function buildFilename(
  ctx: FilenameContext,
  index: number,
  url: string,
  type: MediaKind,
  suffix = "",
): string {
  const platform = sanitizeFilePart(ctx.platform, "post");
  const author = sanitizeFilePart(ctx.author ?? "", "unknown");
  const id = sanitizeFilePart(ctx.id, "unknown");
  const ext = extensionFromUrl(url, type);
  return `EasySave/${platform}_${author}_${id}_${index}${suffix}.${ext}`;
}

/**
 * Expand one parsed media item into concrete download targets.
 * A live item yields both the still image and its motion video.
 */
export function downloadTargets(
  item: MediaItemLike,
  ctx: FilenameContext,
  index: number,
): DownloadTarget[] {
  if (item.type === "live" && item.videoUrl) {
    return [
      { url: item.url, filename: buildFilename(ctx, index, item.url, "image") },
      {
        url: item.videoUrl,
        filename: buildFilename(ctx, index, item.videoUrl, "video", "_live"),
      },
    ];
  }
  const url = item.type === "video" && item.videoUrl ? item.videoUrl : item.url;
  return [{ url, filename: buildFilename(ctx, index, url, item.type) }];
}
