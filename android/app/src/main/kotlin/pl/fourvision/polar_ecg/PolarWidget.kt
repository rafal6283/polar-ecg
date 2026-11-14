package pl.fourvision.polar_ecg

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/** Widżet: poranne HRV (z oceną względem normy) i ostatni napad AF. Dane zapisuje aplikacja. */
class PolarWidget : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        for (id in appWidgetIds) {
            val v = RemoteViews(context.packageName, R.layout.polar_widget)
            v.setTextViewText(R.id.w_hrv, widgetData.getString("w_hrv", "—"))
            v.setTextViewText(R.id.w_hrv_status, widgetData.getString("w_hrv_status", "zmierz rano HRV"))
            val level = widgetData.getString("w_hrv_level", "")
            v.setTextColor(R.id.w_hrv_status, when (level) {
                "low" -> Color.parseColor("#FF8A80")
                "high" -> Color.parseColor("#82B1FF")
                "normal" -> Color.parseColor("#69F0AE")
                else -> Color.parseColor("#9AA7B1")
            })
            v.setTextViewText(R.id.w_af, widgetData.getString("w_af", ""))
            v.setOnClickPendingIntent(R.id.w_root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
            appWidgetManager.updateAppWidget(id, v)
        }
    }
}
