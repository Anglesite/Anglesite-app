# iOS-Assed iPhone and iPad App Specification

**Status:** Evergreen reference specification
**Audience:** Product, design, engineering, QA, and release review
**Targets:** iOS on iPhone and iPadOS on iPad

## Purpose

This specification defines the qualities of an *iOS-assed* app: an app that feels designed for iPhone and iPad, uses each device’s strengths, and integrates with the operating system rather than presenting a desktop or web interface in a touch-sized frame.

iPhone and iPad share Apple platforms and many APIs, but they are not the same context. An iPhone experience should be focused, legible, and comfortable in one- or two-handed use. An iPad experience should use its adaptable display, multitasking, keyboard, pointer, and Apple Pencil capabilities without becoming a shrunken Mac app. This document follows Apple’s current [iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) and [iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) design guidance.

## Product principle

The app should make the primary task feel direct on iPhone and powerful on iPad. People should recognize the navigation, touch behavior, editing, sharing, and permission patterns from the rest of the system. Distinctive branding is welcome; replacing predictable system behavior with custom chrome, hidden gestures, or desktop conventions is not.

## Requirements

### 1. Design for the device and context

- Treat iPhone and iPad as adaptive presentations of the same product, not as one fixed layout scaled up or down. Preserve the user’s task and data while changing navigation, density, and presentation to fit the available space.
- On iPhone, prioritize the current task and content. Keep controls reachable and reduce competing onscreen choices while preserving a clear route to secondary actions.
- On iPad, take advantage of the larger display for meaningful context, browsing, editing, and comparison. Use sidebars, split views, inspectors, multi-column navigation, and drag and drop when they improve the task; do not enlarge a phone layout into empty space.
- Adapt continuously to orientation, Dynamic Type, display size, Split View and other multitasking sizes, Stage Manager or window resizing where supported, external displays, and changes in input mode. Do not make full screen an assumption.
- Respect safe areas, system bars, the on-screen keyboard, sensor housing, and system gestures. Do not place persistent controls where the system can obscure or accidentally invoke them.

### 2. Navigation, commands, and touch

- Use platform-appropriate navigation. Prefer standard tab bars, navigation stacks, sidebars, split views, sheets, popovers, menus, and search patterns when they make the app’s information architecture clearer.
- Keep primary actions visible and close to their content. Put destructive, infrequent, or secondary actions in an appropriate menu, context menu, or confirmation flow—not behind unexplained icon-only controls or a required long press.
- Use standard gestures and preserve their meanings. Support system back navigation where applicable; do not make swipe-only actions undiscoverable or the sole path to important work.
- Ensure touch targets are comfortably sized, separated, and responsive. Do not require precision taps, hover, or a multi-finger gesture for a core action.
- Use context menus and swipe actions as accelerators, never as the only way to discover or perform an important command.
- Let the system handle standard text selection, editing, copy/paste, drag and drop, and input-method behavior whenever possible.

### 3. iPad productivity and external input

- Treat an attached keyboard, pointer or trackpad, and Apple Pencil as first-class iPad inputs while keeping every core action usable by touch alone.
- Provide Command-key shortcuts for frequent, meaningful commands on iPad and honor standard shortcuts such as Command-Z, Command-X, Command-C, Command-V, Command-F, and Command-S when the associated action exists. Do not repurpose established shortcuts for unrelated work.
- Give keyboard users a discoverable command structure and support Full Keyboard Access. Custom controls must expose correct focus, activation, and accessibility behavior.
- Support pointer interaction with appropriate hover, focus, scrolling, selection, and context-menu behavior; pointer affordances must complement, not replace, touch affordances.
- Support drag and drop between views and apps when moving content, files, media, links, or structured objects is part of the task. Use standard item representations so other apps can participate.
- When the product benefits from multiple independent workspaces, support multiple scenes or windows on iPad. Preserve their identity and state instead of forcing every task through a single full-screen scene.

### 4. Windows, scenes, and state

- Restore useful state after interruption, relaunch, or scene activation: the user’s current document or site, selection, navigation position, drafts, and in-progress work where safe.
- Treat each scene as independently interruptible. Do not lose edits because the app moves to the background, the device locks, memory pressure occurs, or another app appears alongside it.
- Use sheets, full-screen covers, alerts, and confirmation dialogs according to their scope. Do not stack modals, block ordinary browsing with a modal step, or use an alert for routine information.
- On iPad, design every scene to remain useful at the full range of supported window sizes. Reduce or collapse secondary structure before hiding the primary content or forcing abrupt mode changes.
- Confirm before discarding unsaved user work. Do not prompt for transient state that the app can safely preserve or restore.

### 5. Files, data, sharing, and interoperability

- Use the system document picker, file importer/exporter, share sheet, photo picker, printing, and Quick Look where they fit the task. Do not replace ordinary system flows with proprietary pickers or custom export screens without a task-specific reason.
- Treat user data as user-owned. Support recognizable formats, maintain fidelity through import/export, and make the data’s local and remote state understandable.
- Support the clipboard with useful standard representations. Use drag and drop and the share sheet to exchange content with other apps instead of creating isolated in-app silos.
- Use the user’s preferred apps and system services for external links, email, maps, payments, and other delegated tasks when appropriate. Do not hard-code a browser or require an account merely to open or export the user’s own data.
- Request file, photo, camera, microphone, location, contacts, calendar, or other protected access only in context, only for a clear feature, and only at the minimum scope needed. Handle denial without trapping the user or losing unrelated work.

### 6. Text, editing, and undo

- Use the system text system for editable text whenever practical. Support selection, standard editing commands, dictation, input methods, text replacement, spell checking where appropriate, and accessibility.
- Make every user-initiated reversible change participate in coherent Undo and Redo. Undo must reverse the action the person reasonably believes they just performed, with sensible grouping for continuous editing.
- Never lose typed or edited content due to focus changes, view recreation, synchronization, app backgrounding, an interrupted scene, or an incomplete undo stack.
- Make destructive actions clear and proportionate to their effect. Offer cancellation or recovery when feasible; do not use an irreversible confirmation as a substitute for a sound data model.

### 7. Accessibility, appearance, and localization

- Meet the functional intent of the current Apple accessibility guidance: meaningful labels, values, traits, hints where needed, logical navigation order, complete VoiceOver operation, and visible or spoken feedback for state changes.
- Verify core flows with VoiceOver, Dynamic Type, Bold Text, Increased Contrast, Reduce Motion, Reduce Transparency, Switch Control, Voice Control, and Full Keyboard Access as applicable.
- Do not communicate essential state only by color, animation, sound, hover, haptics, or a gesture.
- Support the system appearance, accent treatment where appropriate, text scaling, contrast preferences, and right-to-left layout. Use system components and materials so the interface evolves with the platform’s visual language.
- Localize complete phrases and formats, not concatenated fragments. Respect the user’s locale, calendar, time zone, number formats, and input methods.

### 8. System integration, privacy, and reliability

- Integrate purposefully with iOS and iPadOS capabilities that improve the task: Share, Shortcuts and App Intents, Spotlight, widgets, notifications, drag and drop, Quick Look, printing, and Handoff where relevant. Integration must serve a real user journey, not merely advertise the app.
- Use notifications only for timely, actionable information. Respect notification permission, Focus modes, scheduled delivery, and the user’s notification settings.
- Respect the user’s default browser and system settings. Behave predictably when offline, on constrained networks, in Low Power Mode, after interruption, and when background execution is limited.
- Keep the app responsive during work. Explain long-running operations with truthful status and progress, provide cancellation when safe, and avoid blocking interaction with an unexplained spinner.
- Recover clearly from network failure, unavailable accounts, denied permissions, malformed imports, interrupted sharing, and incomplete background work. Explain what happened, what data is safe, and the next useful action.
- Default to privacy-preserving behavior. Do not transmit data, scan user content, start background activity, or request tracking permission without a clear feature-level reason and user-visible control.

### 9. Visual design

- Build around content and task hierarchy, not app chrome. On iPhone, conserve attention and reachability; on iPad, use available space to make work clearer, not merely larger.
- Preserve semantic distinctions in controls. Buttons, links, toggles, text fields, selections, labels, and progress must look and behave according to their roles.
- Use SF Symbols and system controls when suitable. Custom symbols and controls must remain legible at all supported sizes, appearances, contrast settings, and accessibility configurations.
- Avoid fake browser chrome, desktop-style title bars on iPhone, miniature menu bars, tiny densely packed controls, persistent floating action buttons that cover content, and decoration that obscures hierarchy.
- Do not equate an iPad experience with either a stretched iPhone app or a Mac app with touch added. It should be an adaptive iPadOS experience in its own right.

## Implementation guidance

This specification does not mandate SwiftUI, UIKit, or a particular architecture. The chosen implementation is successful only when it provides the required adaptive layout, scene lifecycle, text behavior, accessibility, system integration, and input support. Use UIKit or platform APIs when a framework abstraction cannot deliver correct iPhone or iPad behavior; framework purity is not a reason to ship a degraded experience.

## Explicit non-goals

- Pixel-for-pixel imitation of a particular iOS or iPadOS release.
- Making iPhone and iPad interfaces identical at every size.
- Requiring iPad users to own a keyboard, pointer, or Apple Pencil.
- Requiring every app to support multiple windows, widgets, Handoff, or every system integration.
- Avoiding all custom design or distinctive branding.
- Sacrificing a task-specific improvement for convention when the improvement is demonstrably clearer, accessible, reversible, and consistent with the platform.

## Release acceptance checklist

A feature or release meets this specification when the team can answer “yes” to each applicable question:

- Does the primary iPhone experience remain focused, touch-friendly, reachable, and understandable without hidden essential actions?
- Does the iPad experience adapt meaningfully to wide, narrow, split, and resizable windows instead of simply stretching the iPhone layout?
- Can a touch-only user, a VoiceOver user, and an iPad keyboard or pointer user complete the core flows?
- Do standard text editing, selection, clipboard, drag and drop, Undo/Redo, sharing, import/export, and file behaviors work as users expect?
- Does the app preserve user work through interruption, scene changes, backgrounding, offline operation, and restore?
- Are permissions requested in context and are denial, cancellation, and error paths understandable and safe?
- Has the feature been tested with Dynamic Type, light and dark appearances, increased contrast, reduced motion, VoiceOver, iPhone portrait and landscape where supported, and iPad multitasking/window sizes?
- Is every departure from iOS or iPadOS convention intentional, documented, and demonstrably better for the relevant task?

## Review standard

When a design decision is contested, prefer the option that is most predictable to an experienced iPhone or iPad user, most accessible, most reversible, most respectful of attention and battery, and most supportive of the input and window context the user has chosen. An iOS-assed app earns its character by making iPhone feel immediate and iPad feel adaptable and capable—without mistaking either platform for a miniature desktop or a generic web canvas.
