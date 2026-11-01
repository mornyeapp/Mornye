package com.zarz.mornye

import android.content.Context
import android.os.Bundle
import androidx.annotation.Keep
import androidx.appcompat.view.ContextThemeWrapper
import androidx.mediarouter.app.MediaRouteChooserDialog
import androidx.mediarouter.app.MediaRouteChooserDialogFragment
import androidx.mediarouter.app.MediaRouteControllerDialog
import androidx.mediarouter.app.MediaRouteControllerDialogFragment
import androidx.mediarouter.app.MediaRouteDialogFactory
import androidx.mediarouter.app.MediaRouteDynamicChooserDialog
import androidx.mediarouter.app.MediaRouteDynamicControllerDialog

/** Flutter's Activity theme lacks the opaque AppCompat colors MediaRouter requires. */
internal object MornyeCastDialogs : MediaRouteDialogFactory() {
    override fun onCreateChooserDialogFragment() = MornyeCastChooserFragment()
    override fun onCreateControllerDialogFragment() = MornyeCastControllerFragment()
}

private fun castDialogContext(context: Context): Context =
    ContextThemeWrapper(context, androidx.appcompat.R.style.Theme_AppCompat_DayNight)

@Keep
class MornyeCastChooserFragment : MediaRouteChooserDialogFragment() {
    override fun onCreateChooserDialog(context: Context, savedInstanceState: Bundle?): MediaRouteChooserDialog =
        MediaRouteChooserDialog(castDialogContext(context))

    override fun onCreateDynamicChooserDialog(context: Context): MediaRouteDynamicChooserDialog =
        MediaRouteDynamicChooserDialog(castDialogContext(context))
}

@Keep
class MornyeCastControllerFragment : MediaRouteControllerDialogFragment() {
    override fun onCreateControllerDialog(context: Context, savedInstanceState: Bundle?): MediaRouteControllerDialog =
        MediaRouteControllerDialog(castDialogContext(context))

    override fun onCreateDynamicControllerDialog(context: Context): MediaRouteDynamicControllerDialog =
        MediaRouteDynamicControllerDialog(castDialogContext(context))
}
