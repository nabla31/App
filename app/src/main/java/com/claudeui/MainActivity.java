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
import android.net.Uri;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
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
        "pgrep -f 'node serve[r].js' >/dev/null && exit 0\n"
        + "[ -f ~/claude-ui/server.js ] || exit 1\n"
        + "termux-wake-lock\n"
        + "cd ~/claude-ui && exec node server.js\n";

    private WebView web, dash;
    private Button tabChat, tabDash;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private volatile boolean connected = false;
    private volatile boolean running = true;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().setStatusBarColor(Color.parseColor("#0f0f12"));
        getWindow().setNavigationBarColor(Color.parseColor("#0f0f12"));
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#262624"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "Android");

        dash = new WebView(this);
        dash.setBackgroundColor(Color.parseColor("#262624"));
        WebSettings d = dash.getSettings();
        d.setJavaScriptEnabled(true);
        d.setDomStorageEnabled(true);
        dash.setWebChromeClient(new WebChromeClient());
        dash.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, android.webkit.WebResourceRequest r) {
                String h = r.getUrl().getHost();
                if ("localhost".equals(h) || "127.0.0.1".equals(h)) return false;
                startActivity(new Intent(Intent.ACTION_VIEW, r.getUrl()));
                return true;
            }
            @Override public void onReceivedError(WebView v, android.webkit.WebResourceRequest r, android.webkit.WebResourceError e) {
                if (r.isForMainFrame())
                    v.loadData("<body style='background:#262624;color:#faf9f5;font:16px sans-serif;padding:24px'>OmniRoute ne répond pas.<br>Retourne dans Chat et touche la pastille OmniRoute pour le démarrer.</body>", "text/html", "utf-8");
            }
        });
        dash.setVisibility(View.GONE);

        FrameLayout frame = new FrameLayout(this);
        frame.addView(web, new FrameLayout.LayoutParams(-1, -1));
        frame.addView(dash, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout bar = new LinearLayout(this);
        bar.setBackgroundColor(Color.parseColor("#1d1d1b"));
        tabChat = tab("Chat");
        tabDash = tab("OmniRoute");
        tabChat.setOnClickListener(v -> showTab(false));
        tabDash.setOnClickListener(v -> showTab(true));
        bar.addView(tabChat, new LinearLayout.LayoutParams(0, -2, 1));
        bar.addView(tabDash, new LinearLayout.LayoutParams(0, -2, 1));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#262624"));
        root.addView(frame, new LinearLayout.LayoutParams(-1, 0, 1));
        root.addView(bar, new LinearLayout.LayoutParams(-1, -2));
        setContentView(root);
        showTab(false);
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
        boolean onDash = dash.getVisibility() == View.VISIBLE;
        WebView w = onDash ? dash : web;
        if (w.canGoBack()) w.goBack();
        else if (onDash) showTab(false);
        else super.onBackPressed();
    }

    private Button tab(String t) {
        Button b = new Button(this);
        b.setText(t);
        b.setAllCaps(false);
        b.setTextSize(14);
        b.setBackgroundColor(Color.TRANSPARENT);
        return b;
    }

    private void showTab(boolean d) {
        if (d && dash.getUrl() == null) dash.loadUrl("http://localhost:20128");
        else if (d && dash.getUrl() != null && dash.getUrl().startsWith("data:")) dash.loadUrl("http://localhost:20128");
        dash.setVisibility(d ? View.VISIBLE : View.GONE);
        web.setVisibility(d ? View.GONE : View.VISIBLE);
        tabChat.setTextColor(Color.parseColor(d ? "#a09f98" : "#d97757"));
        tabDash.setTextColor(Color.parseColor(d ? "#d97757" : "#a09f98"));
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

    private void runTermux(String path, String[] args, boolean background, String action) {
        try {
            Intent i = new Intent("com.termux.RUN_COMMAND");
            i.setClassName("com.termux", "com.termux.app.RunCommandService");
            i.putExtra("com.termux.RUN_COMMAND_PATH", path);
            i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args);
            i.putExtra("com.termux.RUN_COMMAND_WORKDIR", HOME);
            i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", background);
            if (action != null) i.putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", action);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
        } catch (Exception e) {
            toast("Termux : " + e.getMessage());
        }
    }

    private void startServer() {
        runTermux(BASH, new String[]{"-c", START_CMD}, false, "3");
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
            int tick = 0;
            while (running) {
                boolean up = ping();
                if (!up && hasPerm() && tick++ % 13 == 0) ui.post(this::startServer);
                if (up) tick = 0;
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
                    runTermux(BASH, new String[]{"-c", readAsset("setup.sh")}, false, null);
                } catch (Exception e) {
                    toast("Erreur : " + e.getMessage());
                }
            });
        }
        @JavascriptInterface public void showDashboard() { ui.post(() -> showTab(true)); }
        @JavascriptInterface public void start() { ui.post(MainActivity.this::startServer); }
    }
}
