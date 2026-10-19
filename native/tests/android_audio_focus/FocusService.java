package dev.lrdp.audiofixture;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/** Private-emulator-only competing app. No network, microphone or playback. */
public final class FocusService extends Service {
    private AudioManager audio;
    private AudioFocusRequest request;
    @Override public void onCreate() {
        super.onCreate();
        audio = (AudioManager)getSystemService(AUDIO_SERVICE);
        ((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(
            new NotificationChannel("lrdp-test", "LRDP audio test", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, "lrdp-test")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("LRDP audio focus test").setContentText("Private emulator fixture").build();
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        else startForeground(1, notification);
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        final int gain = intent == null ? AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            : intent.getIntExtra("gain", AudioManager.AUDIOFOCUS_GAIN_TRANSIENT);
        request = new AudioFocusRequest.Builder(gain)
            .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setOnAudioFocusChangeListener(new AudioManager.OnAudioFocusChangeListener() {
                @Override public void onAudioFocusChange(int change) { }
            }).build();
        int status = audio.requestAudioFocus(request);
        Log.i("LRDPFocusFixture", "focus status=" + status + " gain=" + gain);
        if (status != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) stopSelf();
        return START_NOT_STICKY;
    }
    @Override public void onDestroy() {
        if (request != null) audio.abandonAudioFocusRequest(request);
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
