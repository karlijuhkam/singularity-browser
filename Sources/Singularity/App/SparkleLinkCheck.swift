// TEMPORARY: removed when the updater itself uses Sparkle. Until then this reference makes the
// executable link Sparkle.framework, so the bundle scripts' embedding and signing can be checked.
// It is never called: nothing here starts Sparkle or creates an updater.
import Sparkle

func sparkleLinkCheck() { _ = SPUUpdater.self }
