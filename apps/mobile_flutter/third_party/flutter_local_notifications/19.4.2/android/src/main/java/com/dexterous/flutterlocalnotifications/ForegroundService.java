package com.dexterous.flutterlocalnotifications;

import android.app.Notification;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import androidx.core.content.ContextCompat;
import io.flutter.plugin.common.MethodChannel.Result;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

/** StarChat 19.4.2 fork: acknowledge actual start and close resources natively. */
public class ForegroundService extends Service {
  public interface ResourceOwner {
    boolean canStart();
    void onStarted();
    void release();
    void onStopped(String reason);
  }

  private static final String REQUEST = "chatflow.fgs.request";
  private static final Handler handler = new Handler(Looper.getMainLooper());
  private static final Map<Integer, Result> pending = new HashMap<>();
  private static int nextRequest = 0;
  private static ResourceOwner resourceOwner;
  private static ForegroundService active;
  private boolean closed;
  private int lastAppliedRequest;

  public static void setResourceOwner(ResourceOwner owner) { resourceOwner = owner; }

  static void requestStart(Context context, Intent intent, Result result) {
    if (resourceOwner != null && !resourceOwner.canStart() && !isCallRequest(intent)) {
      result.error("FOREGROUND_SERVICE_DENIED", "Wait for foreground resume", null);
      return;
    }
    final int request = ++nextRequest;
    pending.put(request, result);
    intent.putExtra(REQUEST, request);
    try {
      ContextCompat.startForegroundService(context, intent);
      handler.postDelayed(() -> {
        Result expired = pending.remove(request);
        if (expired != null) {
          expired.error("FOREGROUND_SERVICE_START_TIMEOUT", "No native start acknowledgement", null);
        }
      }, 5000);
    } catch (RuntimeException error) {
      pending.remove(request);
      result.error("FOREGROUND_SERVICE_DENIED", "Android denied foreground service start", null);
    }
  }

  static void cancelPending() {
    for (Result result : pending.values()) {
      result.error("FOREGROUND_SERVICE_STOPPED", "Start was cancelled", null);
    }
    pending.clear();
  }

  static void stopNow() {
    cancelPending();
    if (active != null) active.finishStop("stopped");
  }

  @Override
  public void onCreate() {
    super.onCreate();
    active = this;
  }

  @Override
  @SuppressWarnings("deprecation")
  public int onStartCommand(Intent intent, int flags, int startId) {
    final int request = intent == null ? -1 : intent.getIntExtra(REQUEST, -1);
    final Result result = pending.remove(request);
    // No sticky restart and no late start after a cancelled/timed-out request.
    if (result == null) {
      if (lastAppliedRequest != 0 && request < lastAppliedRequest && !closed) {
        return START_NOT_STICKY; // A cancelled old request cannot close its successor.
      }
      finishStop("cancelled");
      return START_NOT_STICKY;
    }
    try {
      if (resourceOwner != null && !resourceOwner.canStart() && !isCallRequest(intent)) {
        throw new IllegalStateException("Foreground resume required");
      }
      ForegroundServiceStartParameter parameter;
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        parameter = intent.getSerializableExtra(
            ForegroundServiceStartParameter.EXTRA, ForegroundServiceStartParameter.class);
      } else {
        parameter = (ForegroundServiceStartParameter) intent.getSerializableExtra(
            ForegroundServiceStartParameter.EXTRA);
      }
      if (parameter == null) throw new IllegalArgumentException("Missing foreground parameters");
      Notification notification = FlutterLocalNotificationsPlugin.createNotification(
          this, parameter.notificationData);
      if (parameter.foregroundServiceTypes != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        startForeground(parameter.notificationData.id, notification,
            orCombineFlags(parameter.foregroundServiceTypes));
      } else {
        startForeground(parameter.notificationData.id, notification);
      }
      closed = false;
      lastAppliedRequest = request;
      if (resourceOwner != null) resourceOwner.onStarted();
      result.success(null);
    } catch (RuntimeException error) {
      finishStop("denied");
      result.error("FOREGROUND_SERVICE_DENIED", "Android denied foreground service start", null);
    }
    return START_NOT_STICKY;
  }

  private static int orCombineFlags(ArrayList<Integer> flags) {
    int flag = 0;
    for (int value : flags) flag |= value;
    return flag;
  }

  @SuppressWarnings("deprecation")
  private static boolean isCallRequest(Intent intent) {
    if (intent == null) return false;
    ForegroundServiceStartParameter parameter = (ForegroundServiceStartParameter)
        intent.getSerializableExtra(ForegroundServiceStartParameter.EXTRA);
    if (parameter == null || parameter.foregroundServiceTypes == null) return false;
    int types = orCombineFlags(parameter.foregroundServiceTypes);
    // Keep OS microphone/camera permission and start restrictions authoritative.
    return (types & ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) == 0
        && (types & (ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            | ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)) != 0;
  }

  @SuppressWarnings("deprecation")
  private void finishStop(String reason) {
    if (closed) return;
    closed = true;
    // Ordering is mandatory even if Dart is suspended or its engine is gone.
    try {
      if (resourceOwner != null) resourceOwner.release();
    } finally {
      stopForeground(true);
      stopSelf();
    }
    if (resourceOwner != null) resourceOwner.onStopped(reason);
  }

  @Override
  public void onTimeout(int startId) { finishStop("timeout"); }

  @Override
  public void onTimeout(int startId, int fgsType) { finishStop("timeout"); }

  @Override
  public void onDestroy() {
    finishStop("destroyed");
    if (active == this) active = null;
    super.onDestroy();
  }

  @Override
  public IBinder onBind(Intent intent) { return null; }
}
