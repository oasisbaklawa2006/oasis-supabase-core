export function extensionPatternForMediaType(mediaType: string): RegExp {
  switch (mediaType) {
    case "image":
      return /\.(jpg|jpeg|png|webp|gif)$/i;
    case "video":
      return /\.(mp4|mov)$/i;
    case "audio":
      return /\.(opus|ogg|mp3|m4a)$/i;
    default:
      return /\.(pdf|doc|docx)$/i;
  }
}
