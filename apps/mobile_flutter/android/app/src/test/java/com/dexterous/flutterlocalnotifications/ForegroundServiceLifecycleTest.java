package com.dexterous.flutterlocalnotifications;

import static org.junit.Assert.*;
import static org.robolectric.Shadows.shadowOf;

import android.app.Application;
import android.app.Service;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ResolveInfo;
import android.content.pm.ServiceInfo;
import android.os.Looper;
import com.dexterous.flutterlocalnotifications.models.NotificationDetails;
import com.dexterous.flutterlocalnotifications.models.NotificationStyle;
import com.dexterous.flutterlocalnotifications.models.NotificationChannelAction;
import com.dexterous.flutterlocalnotifications.models.styles.DefaultStyleInformation;
import io.flutter.plugin.common.MethodChannel.Result;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35, application = Application.class, manifest = Config.NONE)
public class ForegroundServiceLifecycleTest {
  private Application app;

  private static class Reply implements Result {
    int successes;
    int failures;
    String code;
    public void success(Object value) { successes++; }
    public void error(String code, String message, Object details) {
      failures++;
      this.code = code;
    }
    public void notImplemented() { fail("Unexpected notImplemented"); }
  }

  @Before public void setUp() {
    app = RuntimeEnvironment.getApplication();
    ForegroundService.setResourceOwner(null);
    ForegroundService.cancelPending();
    ResolveInfo activity = new ResolveInfo();
    activity.activityInfo = new ActivityInfo();
    activity.activityInfo.name = "FixtureActivity";
    activity.activityInfo.packageName = app.getPackageName();
    shadowOf(app.getPackageManager()).addResolveInfoForIntent(
        new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .setPackage(app.getPackageName()), activity);
  }

  @After public void tearDown() {
    ForegroundService.stopNow();
    ForegroundService.setResourceOwner(null);
  }

  private Intent startIntent() {
    NotificationDetails details = new NotificationDetails();
    details.id = 41003;
    details.channelId = "test-sync";
    details.channelName = "Test sync";
    details.channelAction = NotificationChannelAction.CreateIfNotExists;
    details.importance = 2;
    details.priority = -1;
    details.title = "Sync";
    details.body = "Fixture";
    details.style = NotificationStyle.Default;
    details.styleInformation = new DefaultStyleInformation(false, false);
    details.iconResourceId = android.R.drawable.ic_dialog_info;
    details.playSound = false;
    details.enableVibration = false;
    details.channelShowBadge = false;
    return new Intent(app, ForegroundService.class).putExtra(
        ForegroundServiceStartParameter.EXTRA,
        new ForegroundServiceStartParameter(details, Service.START_STICKY, null));
  }

  @Test public void acknowledgementWaitsForActualStartAndDisablesStickyRestart() {
    Reply reply = new Reply();
    Intent intent = startIntent();
    ForegroundService.requestStart(app, intent, reply);
    assertEquals(0, reply.successes);
    ForegroundService service = Robolectric.buildService(ForegroundService.class).create().get();
    assertEquals(Service.START_NOT_STICKY, service.onStartCommand(intent, 0, 1));
    assertEquals(1, reply.successes);
    assertEquals(0, reply.failures);
    assertNotNull(shadowOf(service).getLastForegroundNotification());
  }

  @Test public void androidStartDenialReportsFailureNotSuccess() {
    Context denied = new ContextWrapper(app) {
      @Override public ComponentName startForegroundService(Intent intent) {
        throw new IllegalStateException("Background start denied");
      }
    };
    Reply reply = new Reply();
    ForegroundService.requestStart(denied, startIntent(), reply);
    assertEquals(0, reply.successes);
    assertEquals(1, reply.failures);
    assertEquals("FOREGROUND_SERVICE_DENIED", reply.code);
  }

  @Test public void syncResumeGateDoesNotDenyALegalCallStart() {
    ForegroundService.setResourceOwner(new ForegroundService.ResourceOwner() {
      public boolean canStart() { return false; }
      public void onStarted() {}
      public void release() {}
      public void onStopped(String reason) {}
    });
    Intent intent = startIntent();
    ForegroundServiceStartParameter old = (ForegroundServiceStartParameter)
        intent.getSerializableExtra(ForegroundServiceStartParameter.EXTRA);
    intent.putExtra(ForegroundServiceStartParameter.EXTRA,
        new ForegroundServiceStartParameter(old.notificationData, Service.START_NOT_STICKY,
            new ArrayList<>(Collections.singletonList(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE))));
    Reply reply = new Reply();
    ForegroundService.requestStart(app, intent, reply);
    assertEquals(0, reply.failures);
    ForegroundService service = Robolectric.buildService(ForegroundService.class).create().get();
    service.onStartCommand(intent, 0, 1);
    assertEquals(1, reply.successes);
    assertEquals(0, reply.failures);
  }

  @Test public void cancelledStartArrivingLateNeverEntersForeground() {
    Reply reply = new Reply();
    Intent intent = startIntent();
    ForegroundService.requestStart(app, intent, reply);
    ForegroundService.stopNow();
    ForegroundService service = Robolectric.buildService(ForegroundService.class).create().get();
    service.onStartCommand(intent, 0, 1);
    assertTrue(shadowOf(service).isStoppedBySelf());
    assertNull(shadowOf(service).getLastForegroundNotification());
    assertEquals(0, reply.successes);
    assertEquals(1, reply.failures);
  }

  @Test public void missingAcknowledgementIsBoundedAndLateStartCannotReviveIt() {
    Reply reply = new Reply();
    Intent intent = startIntent();
    ForegroundService.requestStart(app, intent, reply);
    shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5));
    assertEquals("FOREGROUND_SERVICE_START_TIMEOUT", reply.code);
    ForegroundService service = Robolectric.buildService(ForegroundService.class).create().get();
    service.onStartCommand(intent, 0, 1);
    assertTrue(shadowOf(service).isStoppedBySelf());
    assertEquals(0, reply.successes);
    assertEquals(1, reply.failures);
  }

  @Test public void cancelledOldRequestCannotStopANewerForegroundSession() {
    Reply oldReply = new Reply();
    Intent oldIntent = startIntent();
    ForegroundService.requestStart(app, oldIntent, oldReply);
    ForegroundService.stopNow();
    Reply newReply = new Reply();
    Intent newIntent = startIntent();
    ForegroundService.requestStart(app, newIntent, newReply);
    ForegroundService service = Robolectric.buildService(ForegroundService.class).create().get();
    service.onStartCommand(newIntent, 0, 2);
    assertEquals(1, newReply.successes);
    service.onStartCommand(oldIntent, 0, 1);
    assertFalse(shadowOf(service).isStoppedBySelf());
    assertEquals(1, oldReply.failures);
  }

  @Test public void malformedStartFailsAndClosesService() {
    Reply reply = new Reply();
    Intent intent = new Intent(app, ForegroundService.class);
    ForegroundService.requestStart(app, intent, reply);
    ForegroundService service = Robolectric.buildService(ForegroundService.class).create().get();
    service.onStartCommand(intent, 0, 1);
    assertEquals("FOREGROUND_SERVICE_DENIED", reply.code);
    assertEquals(0, reply.successes);
    assertTrue(shadowOf(service).isStoppedBySelf());
  }
}
