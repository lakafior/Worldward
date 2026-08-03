# Trademark and Brand Policy

Worldward's **source code** is open under the [Mozilla Public License 2.0](LICENSE).
Its **name and brand** are not.

This isn't an extra restriction bolted onto the licence — it's how the MPL already
works. Section 2.3 of the licence text says so directly:

> This License does not grant any rights in the trademarks, service marks, or logos
> of any Contributor (except as may be necessary to comply with the notice
> requirements in Section 3.4).

This document simply makes that explicit, so nobody has to guess where the line is.

## What is reserved

The following are **not** covered by the MPL-2.0 grant and remain the property of the
Worldward authors:

- The name **Worldward**, and names confusingly similar to it.
- The Worldward app icon and its source layers — everything in
  `Worldward/AppIcon.icon/`, and `website/assets/icon.svg`.
- The product imagery in `Assets/` (mockups and screenshots) and `website/assets/`.
- The identifiers `net.smigi.worldward` and anything derived from it, the App Group
  `group.net.smigi.worldward`, and the iCloud container `iCloud.net.smigi.worldward`.
  Apple enforces these as globally unique in any case — no one else can register them.

Everything else in this repository is MPL-2.0, as marked in each file's header.

## What you may do

Everything the MPL-2.0 allows, including commercially. To be specific, you may:

- Fork the repository, read it, learn from it and modify it.
- Build and run it for yourself, on your own devices, for free, forever.
- Distribute your own modified version — under **your own name and your own icon**.
- Say truthfully that your work is "based on Worldward" or "a fork of Worldward", so
  long as you don't imply that it *is* Worldward or that the Worldward authors
  endorse it.
- Use the name in ordinary descriptive ways that need no permission at all: writing
  about the app, reviewing it, linking to it, filing a bug, packaging it for a
  distribution index.

## What to do when you distribute a fork

If you publish a build anywhere — the App Store, TestFlight, a website, a package
manager — please:

1. **Change the display name.** Set `INFOPLIST_KEY_CFBundleDisplayName` (and the
   `PRODUCT_NAME` of the targets, if you rename them) to something of your own.
2. **Change the bundle identifier**, App Group and iCloud container to your own
   reverse-DNS prefix. You will have to do this anyway to sign and ship.
3. **Replace the app icon** with your own artwork.
4. **Keep the MPL headers** on the files you carried over, and publish your changes
   to those files — that part is the licence, not this policy.

## Asking

If you'd like to use the Worldward name or icon for something not covered above — an
article, a review, a port, a compatible accessory — just ask: `worldward@smigi.net`.
The answer is usually yes.
