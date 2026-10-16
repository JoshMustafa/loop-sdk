package io.loop.core

/**
 * Marks loop-core API that is shared between Loop modules but is not part of
 * the public SDK surface. It can change in any release; apps should not use it.
 */
@RequiresOptIn(
    level = RequiresOptIn.Level.ERROR,
    message = "Internal Loop SDK API, shared between Loop modules. Apps should not use it.",
)
@Retention(AnnotationRetention.BINARY)
@Target(
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.CONSTRUCTOR,
    AnnotationTarget.TYPEALIAS,
)
public annotation class InternalLoopApi
