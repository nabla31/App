package com.claudeui;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    static final String PERM = "com.termux.permission.RUN_COMMAND";
    static final String HOME = "/data/data/com.termux/files/home";
    static final String BASH = "/data/data/com.termux/files/usr/bin/bash";
    static final String APP_URL = "http://localhost:8787";
    static final String LAUNCHER = "file:///android_asset/launcher.html";
    static final String START_CMD =
        "if [ -f ~/claude-ui/server.js ] && ! pgrep -f 'node serve[r].js' >/dev/null; then\n"
        + "  termux-wake-lock\n"
        + "  cd ~/claude-ui\n"
        + "  command -v setsid >/dev/null && S=setsid || S=\n"
        + "  $S nohup node server.js > server.log 2>&1 < /dev/null &\n"
        + "fi\n"
        + "true\n";

    private WebView web;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private volatile boolean connected = false;
    private volatile boolean running = true;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().setStatusBarColor(Color.parseColor("#0f0f12"));
        getWindow().setNavigationBarColor(Color.parseColor("#0f0f12"));
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#0f0f12"));
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "Android");
        web.loadUrl(LAUNCHER);
        if (!hasPerm()) askPerm();
        startPolling();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (!connected && hasPerm()) startServer();
    }

    @Override
    protected void onDestroy() {
        running = false;
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack(); else super.onBackPressed();
    }

    private boolean hasPerm() {
        return Build.VERSION.SDK_INT < 23 || checkSelfPermission(PERM) == PackageManager.PERMISSION_GRANTED;
    }

    private void askPerm() {
        if (Build.VERSION.SDK_INT >= 23) requestPermissions(new String[]{PERM}, 1);
    }

    private void toast(String t) {
        Toast.makeText(this, t, Toast.LENGTH_LONG).show();
    }

    private void runTermux(String path, String[] args, boolean background) {
        try {
            Intent i = new Intent("com.termux.RUN_COMMAND");
            i.setClassName("com.termux", "com.termux.app.RunCommandService");
            i.putExtra("com.termux.RUN_COMMAND_PATH", path);
            i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args);
            i.putExtra("com.termux.RUN_COMMAND_WORKDIR", HOME);
            i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", background);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
        } catch (Exception e) {
            toast("Termux : " + e.getMessage());
        }
    }

    private void startServer() {
        runTermux(BASH, new String[]{"-c", START_CMD}, true);
    }

    private String readAsset(String name) throws Exception {
        try (InputStream is = getAssets().open(name)) {
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = is.read(buf)) > 0) bo.write(buf, 0, n);
            return new String(bo.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private boolean ping() {
        try (Socket sk = new Socket()) {
            sk.connect(new InetSocketAddress("127.0.0.1", 8787), 500);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private void startPolling() {
        new Thread(() -> {
            while (running) {
                boolean up = ping();
                if (up && !connected) {
                    connected = true;
                    ui.post(() -> web.loadUrl(APP_URL));
                } else if (!up && connected) {
                    connected = false;
                    ui.post(() -> web.loadUrl(LAUNCHER));
                }
                try { Thread.sleep(1500); } catch (InterruptedException e) { return; }
            }
        }).start();
    }

    class Bridge {
        @JavascriptInterface public boolean hasPerm() { return MainActivity.this.hasPerm(); }
        @JavascriptInterface public boolean hasTermux() {
            return getPackageManager().getLaunchIntentForPackage("com.termux") != null;
        }
        @JavascriptInterface public void askPerm() { ui.post(MainActivity.this::askPerm); }
        @JavascriptInterface public void openTermux() {
            ui.post(() -> {
                Intent i = getPackageManager().getLaunchIntentForPackage("com.termux");
                if (i != null) startActivity(i); else toast("Termux n'est pas installé (F-Droid).");
            });
        }
        @JavascriptInterface public void copy(String t) {
            ui.post(() -> {
                ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                cm.setPrimaryClip(ClipData.newPlainText("cmd", t));
                toast("Copié");
            });
        }
        @JavascriptInterface public void install() {
            ui.post(() -> {
                try {
                    runTermux(BASH, new String[]{"-c", readAsset("setup.sh")}, false);
                } catch (Exception e) {
                    toast("Erreur : " + e.getMessage());
                }
            });
        }
        @JavascriptInterface public void start() { ui.post(MainActivity.this::startServer); }
    }
}
