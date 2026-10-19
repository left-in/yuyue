# App icon

The icon is 关于's logo (`.v-me-logo` in the prototype, `PhoneAbout` in the app): a bold Songti 阅
on paper (#FBFAF7) with the 墨蓝 rule (#2B4C7E) under it. All sizes come from the logo's own
64-unit box, so the icon and the logo stay the same picture.

Regenerate after changing the logo:

```sh
swift scripts/make_app_icon.swift
cd apple && xcodegen
```

The script writes two things:

- `apple/Yuyue/AppIcon.icon` — the Icon Composer file macOS 26 and iOS 26 use. The paper is the
  icon's fill; 阅 (`glyph.png`) and the rule (`rule.png`) are flat layers on it, no glass, no shadow,
  so the system's own edge and highlight are the only effects.
- `apple/Yuyue/Assets.xcassets/AppIcon.appiconset` — PNGs for macOS 15 (the card on Apple's
  824-of-1024 grid, with the logo's shadow) and iOS 18 to 25 (full bleed; the system rounds it).

Both are named `AppIcon`; Xcode picks the `.icon` on 26 and later and the PNGs before.

If the Dock or Finder still shows an old icon after a rebuild, that's the system's icon cache:
`lsregister -f` the app, or move it once.
