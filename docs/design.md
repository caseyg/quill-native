# Design

The app should feel like it shipped with the phone. These are the rules it follows and where they come from.

## Structure

- **One list, one button.** Home is a single list of drafts and the site’s posts with search and a compose button in the bottom bar, the arrangement Notes and Mail use. There are no tabs: nothing here is a separate area of the app.
- **The composer is the app.** A note opens with the keyboard up and nothing else on screen. Structured posts (event, review, itinerary, weight, exercise) use a standard form.
- **The title names the post type and changes it.** A title menu replaces a grid of type cards.
- **Sign-in asks for one thing**, a domain. The IndieAuth client ID is build configuration, not a question for the person signing in.

## Copy

Apple’s guidance is to keep interface text brief and let controls speak for themselves. So: no taglines, no helper paragraphs, no footers that explain a section. Labels are one or two words in title case. Errors say what happened in one sentence, inline, where the problem is.

## Controls and material

- Standard bars, sheets, lists, menus and pickers throughout, so the app picks up Liquid Glass and its iOS 27 refinements (better diffusion, the system transparency setting, the uniform scroll-edge bar) without custom drawing.
- Glass is used only for the floating control layer: system toolbars and the composer’s action bar. Content never sits on glass, and glass is never stacked.
- Toolbar items are symbols with accessibility labels. Each screen has one prominent action, on the trailing side.
- One accent colour, taken from the icon. Everything else is a system colour, so light, dark, tinted and increased-contrast appearances work.

## Motion and feedback

- The composer zooms out of the compose button or the draft row it came from, and back into it.
- Lists, photo thumbnails, the link preview and detail chips animate in and out with the system’s snappy spring.
- Symbols cross-fade between states (location, syndication, rating) instead of swapping.
- Haptics mark a sent post, a failure, a changed post type and a selection.
- Drafts save themselves. There is no Save button and no confirmation before posting.
- Everything custom respects Reduce Motion and Dynamic Type because it is built from system transitions and text styles.

## Sources

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), Apple
- [Human Interface Guidelines: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), Apple
- [Human Interface Guidelines: Writing](https://developer.apple.com/design/human-interface-guidelines/writing), Apple
- [How Liquid Glass is changing in iOS 27](https://www.macrumors.com/2026/06/10/how-liquid-glass-is-changing-in-ios-27/), MacRumors
- [What’s new in SwiftUI at WWDC 2026](https://iosbuddy.com/blog/whats-new-in-swiftui-at-wwdc-2026), iOSBuddy
- [IndieAuth](https://indieauth.spec.indieweb.org/) and [Micropub](https://micropub.spec.indieweb.org/)
