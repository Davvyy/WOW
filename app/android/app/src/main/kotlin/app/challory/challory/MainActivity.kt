package app.challory.challory

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

// Android 14 Health Connect 권한 화면(ActivityResultContract)이 FragmentActivity를 요구한다.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    // FCM 기본 채널(AndroidManifest 의 default_notification_channel_id). 이미 있으면 그대로 둔다.
    // 중요도 기본: 소리는 나지만 다른 앱 위로 튀어나오지 않는다.
    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "챌로리 알림", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "분석 완료·저녁 리마인드·어제 결과·검토 안내"
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "challory"
    }
}
