// @ts-check
import { defineConfig } from "astro/config";
import UnoCSS from "unocss/astro";

export default defineConfig({
  site: "https://edmund.md",
  // Astro 7's compressor drops the space at a line break before an inline tag
  // ("is <i>native" became "is<i>native"), gluing words together in the copy.
  compressHTML: false,
  integrations: [
    UnoCSS({
      injectReset: true,
    }),
  ],
});
