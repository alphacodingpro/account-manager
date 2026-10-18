/** Turns an uploaded logo into a small PNG/JPEG data URL that fits the database limit. */
const MAX_INPUT = 5 * 1024 * 1024;
const MAX_CHARS = 380_000;

function loadImage(file: File): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("This file is not a readable image.")); };
    img.src = url;
  });
}

export async function fileToLogoDataUrl(file: File): Promise<string> {
  if (!/^image\/(png|jpe?g|webp)$/i.test(file.type)) throw new Error("Choose a PNG, JPG or WebP image.");
  if (file.size > MAX_INPUT) throw new Error("The image is larger than 5 MB. Choose a smaller file.");
  const img = await loadImage(file);
  const keepAlpha = /png|webp/i.test(file.type);
  for (const maxWidth of [520, 400, 300, 220]) {
    const scale = Math.min(1, maxWidth / img.width, (maxWidth * 0.45) / img.height);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(img.width * scale));
    canvas.height = Math.max(1, Math.round(img.height * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("This browser cannot process images.");
    if (!keepAlpha) { ctx.fillStyle = "#ffffff"; ctx.fillRect(0, 0, canvas.width, canvas.height); }
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    const url = keepAlpha ? canvas.toDataURL("image/png") : canvas.toDataURL("image/jpeg", 0.88);
    if (url.length <= MAX_CHARS) return url;
    const jpeg = canvas.toDataURL("image/jpeg", 0.8);
    if (jpeg.length <= MAX_CHARS) return jpeg;
  }
  throw new Error("The logo is too detailed. Use a simpler or smaller image.");
}
