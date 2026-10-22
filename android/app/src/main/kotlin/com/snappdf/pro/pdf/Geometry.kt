package com.snappdf.pro.pdf

import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * 2D affine transform in PDF matrix notation:
 *   x' = a*x + c*y + e
 *   y' = b*x + d*y + f
 */
data class Affine(
    val a: Double, val b: Double,
    val c: Double, val d: Double,
    val e: Double, val f: Double,
) {
    fun apply(x: Double, y: Double): Pair<Double, Double> =
        Pair(a * x + c * y + e, b * x + d * y + f)

    /** Returns the transform that applies `this` first and then [next]. */
    fun then(next: Affine): Affine = Affine(
        a = next.a * a + next.c * b,
        b = next.b * a + next.d * b,
        c = next.a * c + next.c * d,
        d = next.b * c + next.d * d,
        e = next.a * e + next.c * f + next.e,
        f = next.b * e + next.d * f + next.f,
    )

    companion object {
        val IDENTITY = Affine(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
        fun translate(tx: Double, ty: Double) = Affine(1.0, 0.0, 0.0, 1.0, tx, ty)
        fun scale(sx: Double, sy: Double) = Affine(sx, 0.0, 0.0, sy, 0.0, 0.0)

        /**
         * Rotation that appears clockwise on screen when applied in a y-down
         * coordinate system (display space).
         */
        fun rotateClockwiseYDown(degrees: Double): Affine {
            val r = Math.toRadians(degrees)
            return Affine(cos(r), sin(r), -sin(r), cos(r), 0.0, 0.0)
        }
    }
}

/**
 * Describes how a PDF page is presented on screen and maps between the
 * "display space" used by the Flutter UI and PDF user space.
 *
 * Display space: origin at the top-left of the visible (crop) box as the page
 * appears after applying /Rotate, units are PDF points, y grows downwards.
 */
class PageGeometry(
    /** Crop box lower-left x/y and size in user space. */
    val boxX: Double,
    val boxY: Double,
    val boxWidth: Double,
    val boxHeight: Double,
    rotation: Int,
) {
    /** Rotation normalised to 0, 90, 180 or 270 (clockwise, as in /Rotate). */
    val rotation: Int = normalizeRotation(rotation)

    val displayWidth: Double get() = if (rotation % 180 == 0) boxWidth else boxHeight
    val displayHeight: Double get() = if (rotation % 180 == 0) boxHeight else boxWidth

    /** Maps display-space points to user-space points. */
    val displayToUser: Affine = when (this.rotation) {
        0 -> Affine(1.0, 0.0, 0.0, -1.0, boxX, boxY + boxHeight)
        90 -> Affine(0.0, 1.0, 1.0, 0.0, boxX, boxY)
        180 -> Affine(-1.0, 0.0, 0.0, 1.0, boxX + boxWidth, boxY)
        else -> Affine(0.0, -1.0, -1.0, 0.0, boxX + boxWidth, boxY + boxHeight)
    }

    /**
     * Transform for drawing a unit-square XObject (image) so that it fills the
     * display rectangle ([x], [y], [w], [h]) upright, optionally rotated
     * clockwise (on screen) by [rotationDegrees] around its centre.
     */
    fun imageMatrix(x: Double, y: Double, w: Double, h: Double, rotationDegrees: Double = 0.0): Affine {
        // Unit square (0..1, y-up) -> rectangle of size w*h with top-left at origin, y-down.
        val unitToBox = Affine(w, 0.0, 0.0, -h, 0.0, h)
        val centred = unitToBox.then(Affine.translate(-w / 2, -h / 2))
            .then(Affine.rotateClockwiseYDown(rotationDegrees))
            .then(Affine.translate(x + w / 2, y + h / 2))
        return centred.then(displayToUser)
    }

    /**
     * Text matrix for a baseline starting at display point ([x], [baselineY]),
     * so glyphs appear upright on screen. [horizontalScale] stretches glyphs
     * horizontally (1.0 = natural width).
     */
    fun textMatrix(x: Double, baselineY: Double, rotationDegrees: Double = 0.0, pivotX: Double = x, pivotY: Double = baselineY): Affine {
        val flip = Affine(1.0, 0.0, 0.0, -1.0, x, baselineY)
        val rotated = if (rotationDegrees == 0.0) flip else flip
            .then(Affine.translate(-pivotX, -pivotY))
            .then(Affine.rotateClockwiseYDown(rotationDegrees))
            .then(Affine.translate(pivotX, pivotY))
        return rotated.then(displayToUser)
    }

    companion object {
        fun normalizeRotation(rotation: Int): Int {
            val r = ((rotation % 360) + 360) % 360
            return ((r / 90.0).roundToInt() * 90) % 360
        }
    }
}
