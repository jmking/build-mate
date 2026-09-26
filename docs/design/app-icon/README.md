# Build Mate app icon

An original structural M made of two facing beams. The monochrome palette connects it to developer tools without reproducing the Codex or OpenAI logos. This is an original design direction, not a trademark-clearance opinion.

The foreground artwork was generated with the built-in image-generation tool. The transparent source is `build-mate-mark.png`.

## Native app asset

Open [`BuildMate.icon`](../../../BuildMate/BuildMate.icon) in Apple's Icon Composer to edit the layered macOS icon. Its foreground uses the generated mark's alpha shape at 82% scale. Icon Composer supplies the material, lighting, shadow and rounded tile; these are not painted into the foreground artwork.

- Default/light: graphite mark on the system light tile.
- Dark: pearl mark on the system dark tile.
- macOS chooses the icon appearance through its icon appearance settings, which may differ from the app's colour scheme.

`project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME` to `BuildMate`. Xcode compiles the `.icon` resource into the app's asset catalogue and compatibility `.icns` file.

| Light | Dark |
|---|---|
| ![Light icon](build-mate-light.png) | ![Dark icon](build-mate-dark.png) |

These previews use the macOS 26 design generation. Regenerate from the repository root with the Icon Composer executable bundled in the installed Xcode (use `Dark` and `build-mate-dark.png` for the other appearance):

```sh
'/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool' BuildMate/BuildMate.icon --export-image --output-file docs/design/app-icon/build-mate-light.png --platform macOS --rendition Default --width 512 --height 512 --scale 1 --design-generation 26
```

Reference: [Apple Icon Composer](https://developer.apple.com/icon-composer/).

## Generation prompt

Use case: logo-brand. Asset type: foreground artwork for an original native macOS app icon for Build Mate, a calm professional tool for building software with AI agents. Create a single bold, exceptionally simple, geometric construction monogram: two interlocking upright structural brackets or beams that together suggest a lowercase/abstract M and a small open doorway in negative space. Solid near-black silhouette, balanced bilateral structure, subtly softened corners, strong clear negative space, recognizable at 16 pixels. Premium restrained precision, not playful. Centered in a square 1024 x 1024 canvas; mark occupies roughly 60% of canvas width and height, ample completely transparent surrounding margin. Flat vector-like crisp artwork only, not a mockup. No background tile, no shadow, no lighting, no 3D, no gradient, no text or wordmark, no tiny construction details, no hammer. Entirely original geometry. Do not depict or imitate any existing brand logo: no OpenAI knot/rosette, no Codex mark, no terminal chevron/underscore, no interwoven loops, no hexagonal badge. The association with coding tools should come only from monochrome simplicity. Output real alpha transparency.

The generated app product is `Build Mate.app` (executable `BuildMate`). This keeps Finder/Dock bundle naming consistent with the display name and avoids reusing the old development bundle’s cached generic icon. Launch the spaced product path shown in AGENTS.md.
