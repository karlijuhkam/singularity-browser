// Pictures in a note.
//
// In the Markdown a picture is `![](assets/2026-11-16-a1b2c3d4.png)`: a path relative to the
// note's own folder. The page can't load that path as written (the page's address is not the
// note's folder), so on screen the picture's address becomes `/file/assets/…`, which the app
// answers from the note's folder. The document itself always keeps the path as written.
//
// A picture whose address is on the web is not loaded (the page has no network, on purpose: a
// note must not be able to tell a server that it was opened). Its description is shown instead.

import Image from "@tiptap/extension-image";

const filePrefix = "/file/";

/** The address the page loads for a picture path written in the Markdown. "" when it isn't a file of the note. */
export function shownSource(source: string | null): string {
  if (!source || /^[a-z][a-z0-9+.-]*:/i.test(source) || source.startsWith("/") || source.startsWith("\\")) return "";
  return filePrefix + source;
}

/** The reverse, for a picture copied inside the editor and pasted back. */
export function writtenSource(shown: string | null): string | null {
  if (!shown) return null;
  let path = shown;
  try {
    const url = new URL(shown, location.href);
    if (url.origin === location.origin) path = url.pathname;
  } catch { /* keep as written */ }
  return path.startsWith(filePrefix) ? path.slice(filePrefix.length) : shown;
}

export const NoteImage = Image.extend({
  addAttributes() {
    return {
      ...this.parent?.(),
      src: {
        default: null,
        parseHTML: (element) => element.getAttribute("data-source") ?? writtenSource(element.getAttribute("src")),
        renderHTML: (attributes) => {
          const shown = shownSource(attributes.src);
          return shown
            ? { src: shown, "data-source": attributes.src }
            : { "data-source": attributes.src, "data-remote": "", alt: attributes.alt || attributes.src || "Picture" };
        },
      },
    };
  },
});

const imageTypes = new Set(["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic"]);

/** The picture files in a paste or drop. */
export function imageFiles(data: DataTransfer | null | undefined): File[] {
  return [...(data?.files ?? [])].filter((file) => imageTypes.has(file.type));
}

export function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error("the picture couldn't be read"));
    reader.onload = () => {
      // "data:image/png;base64,AAAA…": only the part after the comma.
      const text = String(reader.result);
      resolve(text.slice(text.indexOf(",") + 1));
    };
    reader.readAsDataURL(file);
  });
}
