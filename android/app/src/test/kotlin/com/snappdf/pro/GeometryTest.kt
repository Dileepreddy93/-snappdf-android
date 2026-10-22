package com.snappdf.pro

import com.snappdf.pro.pdf.Affine
import com.snappdf.pro.pdf.PageGeometry
import org.junit.Assert.assertEquals
import org.junit.Test

class GeometryTest {
    private fun assertPoint(expected: Pair<Double, Double>, actual: Pair<Double, Double>) {
        assertEquals(expected.first, actual.first, 1e-6)
        assertEquals(expected.second, actual.second, 1e-6)
    }

    @Test
    fun rotationNormalisation() {
        assertEquals(0, PageGeometry.normalizeRotation(360))
        assertEquals(270, PageGeometry.normalizeRotation(-90))
        assertEquals(90, PageGeometry.normalizeRotation(450))
        assertEquals(180, PageGeometry.normalizeRotation(185))
    }

    @Test
    fun displayCornersMapToTheRightUserCorners() {
        // Crop box offset (10, 20), 100 x 200 points.
        val r0 = PageGeometry(10.0, 20.0, 100.0, 200.0, 0)
        assertEquals(100.0, r0.displayWidth, 0.0)
        assertPoint(10.0 to 220.0, r0.displayToUser.apply(0.0, 0.0))     // top-left -> user top-left
        assertPoint(110.0 to 20.0, r0.displayToUser.apply(100.0, 200.0)) // bottom-right

        val r90 = PageGeometry(10.0, 20.0, 100.0, 200.0, 90)
        assertEquals(200.0, r90.displayWidth, 0.0)
        assertEquals(100.0, r90.displayHeight, 0.0)
        // Rotated clockwise: display top-left is user bottom-left.
        assertPoint(10.0 to 20.0, r90.displayToUser.apply(0.0, 0.0))
        assertPoint(10.0 to 220.0, r90.displayToUser.apply(200.0, 0.0))
        assertPoint(110.0 to 20.0, r90.displayToUser.apply(0.0, 100.0))

        val r180 = PageGeometry(10.0, 20.0, 100.0, 200.0, 180)
        assertPoint(110.0 to 20.0, r180.displayToUser.apply(0.0, 0.0))
        assertPoint(10.0 to 220.0, r180.displayToUser.apply(100.0, 200.0))

        val r270 = PageGeometry(10.0, 20.0, 100.0, 200.0, 270)
        assertPoint(110.0 to 220.0, r270.displayToUser.apply(0.0, 0.0))
        assertPoint(10.0 to 20.0, r270.displayToUser.apply(200.0, 100.0))
    }

    @Test
    fun affineCompositionOrder() {
        val t = Affine.translate(5.0, 0.0).then(Affine.scale(2.0, 2.0))
        assertPoint(12.0 to 2.0, t.apply(1.0, 1.0)) // (1+5)*2, 1*2
        val rot = Affine.rotateClockwiseYDown(90.0)
        // In y-down space, clockwise 90: +x axis -> +y axis.
        assertPoint(0.0 to 1.0, rot.apply(1.0, 0.0))
    }

    @Test
    fun imageMatrixFillsDisplayRectUpright() {
        for (rotation in listOf(0, 90, 180, 270)) {
            val g = PageGeometry(0.0, 0.0, 600.0, 800.0, rotation)
            val m = g.imageMatrix(50.0, 70.0, 200.0, 100.0)
            val toDisplay = inverse(g.displayToUser)
            // Image unit-square top-left (0,1) must land at display (50,70).
            assertPoint(50.0 to 70.0, m.then(toDisplay).apply(0.0, 1.0))
            // Unit-square bottom-right (1,0) at display (250,170).
            assertPoint(250.0 to 170.0, m.then(toDisplay).apply(1.0, 0.0))
        }
    }

    private fun inverse(m: Affine): Affine {
        val det = m.a * m.d - m.b * m.c
        val a = m.d / det
        val b = -m.b / det
        val c = -m.c / det
        val d = m.a / det
        return Affine(a, b, c, d, -(a * m.e + c * m.f), -(b * m.e + d * m.f))
    }
}
