package com.saarathi.saarathi

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ObjectAnimator
import android.os.Bundle
import android.view.animation.AnticipateInterpolator
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Must be called before super.onCreate() per the Splash Screen API.
        // On API 31+ this hooks into the real system splash our theme
        // already declares (values-v31/styles.xml) and lets us customize
        // its exit; it's a safe no-op on older API levels, which keep using
        // the separate legacy drawable-based splash untouched.
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)

        splashScreen.setOnExitAnimationListener { splashScreenView ->
            // A quick fade + shrink on the icon as the splash hands off to
            // the first Flutter frame, instead of the plain instant cut.
            val fadeOut = ObjectAnimator.ofFloat(
                splashScreenView.iconView, "alpha", 1f, 0f
            )
            val scaleX = ObjectAnimator.ofFloat(
                splashScreenView.iconView, "scaleX", 1f, 0.7f
            )
            val scaleY = ObjectAnimator.ofFloat(
                splashScreenView.iconView, "scaleY", 1f, 0.7f
            )
            fadeOut.interpolator = AnticipateInterpolator()
            scaleX.interpolator = AnticipateInterpolator()
            scaleY.interpolator = AnticipateInterpolator()
            fadeOut.duration = 260L
            scaleX.duration = 260L
            scaleY.duration = 260L

            fadeOut.addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    splashScreenView.remove()
                }
            })

            fadeOut.start()
            scaleX.start()
            scaleY.start()
        }
    }
}
