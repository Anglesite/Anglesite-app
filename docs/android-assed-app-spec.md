# Android-Assed Phone and Tablet App Specification

**Status:** Evergreen reference specification
**Audience:** Product, design, engineering, QA, and release review
**Targets:** Android phones, tablets, foldables, and resizable Android windows

## Purpose

This specification defines the qualities of an *Android-assed* app: an app that feels made for Android, uses the system’s navigation, sharing, accessibility, adaptive-layout, and permission models, and remains dependable across the range of Android devices people actually use.

Android phones and tablets share a platform but not a single context. A phone experience should be touch-first, focused, and comfortable in everyday use. A tablet, foldable, ChromeOS, or desktop-windowed Android experience must adapt to the available app window, support richer input, and make useful use of space without simply stretching the phone UI. This specification follows Android’s current [adaptive-app guidance](https://developer.android.com/develop/adaptive-apps/guides/get-started-with-adaptive-apps), [layout and navigation patterns](https://developer.android.com/design/ui/mobile/guides/layout-and-content/layout-and-nav-patterns), and [accessibility guidance](https://developer.android.com/design/ui/mobile/guides/foundations/accessibility).

## Product principle

The app should make a person feel oriented and in control. They should understand where Back will take them, what an action changes, how to share or open content in another app, what access they have granted, and how the interface will behave when the window or device changes. The product may have its own voice, but it must not replace Android’s reliable patterns with a generic web shell or another platform’s conventions.

## Requirements

### 1. Adaptive, device-aware design

- Treat window size and configuration as runtime inputs, not a device-class assumption. Adapt to compact, medium, and expanded windows; orientation; multi-window and desktop windowing; display density; font scale; external displays; and foldable posture or hinge position when relevant.
- On phones, focus the interface on the current task and keep touch targets comfortable, reachable, and uncluttered. Do not require a large-screen layout, a pointer, or precision tapping to complete core work.
- On tablets and other expanded windows, show additional useful context instead of merely expanding margins. Use list-detail, supporting-pane, grid, navigation rail, sidebar, inspector, or multi-pane patterns when they make browsing, editing, or comparison clearer.
- Allow the application to resize and fill the available window. Do not lock orientation, aspect ratio, or resizability as a substitute for adaptive layout, and do not letterbox or crop essential controls on large displays.
- Preserve task continuity through rotation, window resizing, fold/unfold transitions, configuration changes, and process recreation. Never lose a draft, selection, in-progress operation, or unsaved user work because the layout changes.

### 2. Navigation, Back, and commands

- Use Android navigation patterns intentionally: a navigation bar, navigation rail, drawer, tabs, top app bar, list-detail flow, and search should each have a clear role in the information architecture.
- Make the system Back action—gesture or button—predictable. It should dismiss the current transient surface, move within the current task hierarchy, or leave the app according to the user’s navigation history; it must not unexpectedly discard data, jump to an unrelated destination, or silently perform a destructive action.
- Support the current predictive Back experience where applicable, so the system can preview the destination and users retain confidence in the gesture.
- Keep the primary action clear and close to the relevant content. A floating action button is appropriate only for one prominent, contextually stable action; do not use it as a universal substitute for a command structure.
- Use overflow menus, contextual actions, long-press menus, and swipe actions as accelerators, never as the sole way to discover or perform an important action.
- Make destructive actions explicit, scoped, and recoverable where feasible. Explain the result before an irreversible action and provide Undo when the operation can safely be reversed.

### 3. Touch, keyboard, pointer, and stylus

- Make every core flow usable with touch. Use comfortable touch targets, standard scrolling and selection behavior, and responsive gesture feedback; do not require hover, a physical keyboard, or multi-finger gestures.
- Support physical keyboard navigation and shortcuts when the device has a keyboard or the task benefits from it. Preserve standard editing shortcuts such as Ctrl-Z, Ctrl-X, Ctrl-C, Ctrl-V, Ctrl-A, Ctrl-F, and Ctrl-S when their associated actions exist; never repurpose them for unrelated work.
- Provide a logical focus order and visible focus indication for keyboard and D-pad navigation. Custom components must expose correct focus, activation, selection, and scrolling behavior.
- Treat mouse and trackpad input as a first-class supplement on tablets, ChromeOS, and desktop-windowed Android. Support expected pointing, scrolling, selection, hover, context-menu, and drag behavior without making touch users second-class.
- Support stylus input, handwriting, and precision selection when they help the task. Do not reserve ordinary editing or controls for a stylus-specific interaction.
- Use drag and drop within the app and between apps when moving files, media, links, or structured items is a meaningful user workflow. Provide compatible standard data representations.

### 4. Windows, tasks, and lifecycle

- Treat each visible window or task as independently interruptible. Save essential UI and document state so the app can recover after backgrounding, process death, low memory, split-screen use, or task switching.
- Design all screens to work in narrow, wide, short, and tall windows. Ensure that scrolling and alternative layouts make every action reachable when the keyboard, system bars, or a second app reduces the available area.
- Use dialogs, bottom sheets, menus, and full-screen destinations according to their scope. Do not stack modals, block routine exploration with confirmation dialogs, or use a full-screen interruption for a lightweight choice.
- Support multiple activities, documents, or windows when users benefit from independently viewing or comparing work. Do not force such work through one fixed full-screen task.
- Respect the system’s activity/task ownership. Do not simulate a custom app switcher, interfere with Recents, or treat leaving the foreground as equivalent to quitting or abandoning work.

### 5. Data, files, sharing, and interoperability

- Use Android’s Storage Access Framework, system document picker, photo picker, share sheet, print framework, and chooser intents where they fit the task. Do not require broad storage permission or replace ordinary system flows with proprietary pickers without a compelling task-specific reason.
- Treat user data as user-owned. Support recognizable formats, preserve fidelity through import and export, and make clear whether content is local, synced, pending, or unavailable offline.
- Support the clipboard, sharing, and inter-app exchange through useful standard MIME types and Android intents. Use App Links or verified links where appropriate, and open external URLs with the user’s preferred handler rather than a hard-coded browser.
- Request the narrowest data access required for the feature. Do not ask for all files, photos, contacts, location, camera, microphone, notifications, or tracking-like access before the user invokes a feature that needs it.
- Respect selected documents, removable media, managed-device policy, work profiles, multiple user profiles, and content-provider permissions. Handle revoked access, unavailable content, and denied chooser results without corrupting unrelated work.

### 6. Text, editing, and undo

- Use Android’s text and input systems whenever practical. Text must support selection, insertion, standard clipboard behavior, input methods, autocorrect and spell checking where appropriate, dictation, accessibility, and hardware-keyboard editing.
- Make every user-initiated reversible change participate in coherent Undo and Redo where the task supports it. Undo should reverse the action the person reasonably believes they just performed, with sensible grouping for continuous edits.
- Never lose typed or edited content because focus changes, the IME opens or closes, the device rotates, a composable/view is recreated, a sync refresh occurs, or the process is restarted.
- Keep validation constructive and local to the problem. Preserve entered information when a form fails validation, explain how to fix it, and do not force users to re-enter unaffected fields.

### 7. Accessibility, appearance, and localization

- Meet the functional intent of current Android accessibility guidance: meaningful content descriptions, roles, states, values, headings, traversal order, focus behavior, action labels, and programmatic announcements for meaningful changes.
- Verify core flows with TalkBack, Switch Access, Voice Access, keyboard navigation, screen magnification, and the selected toolkit’s accessibility inspection tools. A custom component is incomplete until it works with assistive technology.
- Support font scaling, display scaling, high contrast and color correction where relevant, bold text, reduced motion, and adequate contrast. Do not convey essential state solely through color, sound, animation, vibration, hover, or a gesture.
- Follow Material and the user’s system appearance where it makes the app clearer. Support light and dark themes, dynamic color or system theming when appropriate, and edge-to-edge layouts that keep content and controls visible around system bars.
- Localize complete messages and use locale-aware dates, times, numbers, calendars, input methods, and right-to-left layout. Do not concatenate text fragments that translators must reorder.

### 8. System integration, privacy, and reliability

- Integrate purposefully with Android capabilities that improve the task: shares, intents, App Links, widgets, shortcuts, notifications, system search, media controls, printing, and background work. Integrations must serve a real user journey, not merely advertise the app.
- Use notification channels and notifications only for timely, actionable information. Respect notification permission, channel controls, Do Not Disturb, and the user’s settings; never use notifications as a substitute for a reliable in-app state model.
- Respect the user’s preferred browser, system settings, locale, time zone, input methods, battery and data-saver settings, network constraints, and managed-device policies.
- Use Android’s lifecycle and background-work facilities correctly. Do not hold unnecessary foreground services, background processes, wake locks, or network connections. Explain and make controllable any continuous background behavior the product genuinely needs.
- Keep the interface responsive. Run expensive work outside the main thread, expose meaningful progress for operations that take time, and provide safe cancellation when possible.
- Recover clearly from offline work, denied permissions, missing handlers, unavailable accounts, malformed imports, interrupted sharing, background restrictions, and interrupted updates. State what happened, what data is safe, and the next useful action.
- Default to privacy-preserving behavior. Do not transmit data, scan user content, begin background work, or collect identifiers beyond what a clearly explained feature requires.

### 9. Visual design

- Build around content hierarchy and Material semantics, not decorative app chrome. On phones, favor clarity and reachability; on tablets, use additional space to reveal context and tools that improve work.
- Preserve semantic distinction in controls. Buttons, links, toggles, text fields, list selections, tabs, labels, progress, and errors must look and behave according to their roles.
- Use icons only when their meaning is established or accompanied by a label. Custom icons must remain legible at all supported sizes, themes, contrast levels, and font/display scales.
- Avoid fake browser chrome, iOS-style navigation and Back affordances, desktop title bars on phones, tiny dense controls, unexplained gesture-only interactions, and decoration that obscures hierarchy or state.
- Do not equate a tablet experience with an enlarged phone screen. It should be an adaptive Android experience that works in the actual window and input context the user has chosen.

## Implementation guidance

This specification does not mandate Jetpack Compose, Views, Kotlin, Java, or a particular architecture. Compose Material 3 and the adaptive libraries are natural choices for a modern Android app, but the implementation is successful only if it provides the required adaptive layout, Back behavior, lifecycle continuity, accessibility, system integration, and multi-input support. Use platform APIs or interoperable components when an abstraction cannot deliver correct Android behavior; framework purity is not a reason to ship a degraded experience.

## Explicit non-goals

- Pixel-for-pixel imitation of a particular Android release, device skin, or manufacturer launcher.
- Making phone and tablet interfaces identical at every size.
- Requiring tablet users to own a keyboard, pointer, stylus, foldable, or external display.
- Requiring every app to support widgets, shortcuts, multiple windows, every form factor, or every Android intent surface.
- Avoiding all custom design or distinctive branding.
- Sacrificing a task-specific improvement for convention when the improvement is demonstrably clearer, accessible, reversible, and consistent with the platform.

## Release acceptance checklist

A feature or release meets this specification when the team can answer “yes” to each applicable question:

- Does the phone experience remain focused, touch-friendly, and understandable, with a predictable system Back journey and no hidden essential action?
- Does the tablet and large-window experience adapt its navigation, density, and content structure instead of merely stretching the phone layout?
- Can touch-only, TalkBack, Switch Access, keyboard, and pointer users complete the core flows that apply to their device?
- Do standard text editing, selection, clipboard, sharing, drag and drop, import/export, and Undo/Redo behavior work as users expect?
- Does the app retain user work through rotation, resize, fold/unfold posture changes, backgrounding, process recreation, offline work, and task switching?
- Are permission requests contextual and minimal, and are denial, cancellation, and error paths understandable and safe?
- Has the feature been tested with gesture and three-button navigation, font and display scaling, light and dark themes, TalkBack, narrow and wide windows, tablet/foldable configurations, keyboard and pointer input, and realistic offline or constrained-network conditions?
- Is every departure from Android convention intentional, documented, and demonstrably better for the relevant task?

## Review standard

When a design decision is contested, prefer the option that is most predictable to an experienced Android user, most adaptive to the available app window, most accessible, most reversible, and most respectful of the user’s attention, battery, data, and system control. An Android-assed app earns its character by feeling direct on a phone and capable on a tablet—while working gracefully across the diverse Android ecosystem rather than assuming one screen, one device, or one input method.
