package com.claudeui;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Toast;

public class ResultReceiver extends BroadcastReceiver {
    public static volatile String last = "";

    @Override
    public void onReceive(Context c, Intent i) {
        Bundle r = i.getBundleExtra("result");
        if (r == null) return;
        int code = r.getInt("exitCode", 0);
        String msg = (r.getString("errmsg", "") + " " + r.getString("stderr", "") + " " + r.getString("stdout", "")).trim();
        if (code != 0 || !msg.isEmpty()) {
            last = msg.isEmpty() ? "code " + code : msg;
            Toast.makeText(c, "Termux : " + last, Toast.LENGTH_LONG).show();
        }
    }
}
