package com.claudeui;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.SharedPreferences;
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
import android.graphics.drawable.GradientDrawable;
import android.transition.TransitionManager;
import android.widget.ImageView;
import android.widget.TextView;
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
    static final String START_BG =
        "pgrep -f 'node serve[r].js' >/dev/null && exit 0\n"
        + "[ -f ~/claude-ui/server.js ] || { echo \"Claude UI n'est pas installé : appuie sur Installer.\"; exit 1; }\n"
        + "termux-wake-lock\n"
        + "cd ~/claude-ui && exec node server.js >> server.log 2>&1\n";
    static final String START_VIS =
        "pgrep -f 'node serve[r].js' >/dev/null && exit 0\n"
        + "[ -f ~/claude-ui/server.js ] || { echo \"Claude UI n'est pas installé : appuie sur Installer.\"; sleep 5; exit 1; }\n"
        + "termux-wake-lock\n"
        + "cd ~/claude-ui && exec node server.js\n";

    private WebView web, dash;
    private LinearLayout navBar, navWrap, rootView;
    private final LinearLayout[] navItems = new LinearLayout[3];
    private final ImageView[] navIcons = new ImageView[3];
    private final TextView[] navLabels = new TextView[3];
    private int sel = 0, accent = Color.parseColor("#d97757");
    private boolean dark = true;
    private SharedPreferences prefs;
    private volatile boolean lastVisible = false;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private volatile boolean connected = false;
    private volatile boolean running = true;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = getSharedPreferences("cui", MODE_PRIVATE);
        getWindow().setStatusBarColor(Color.parseColor("#1b1a19"));
        getWindow().setNavigationBarColor(Color.parseColor("#1b1a19"));
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#1b1a19"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "Android");

        dash = new WebView(this);
        dash.setBackgroundColor(Color.parseColor("#1b1a19"));
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
                    v.loadData("<body style='background:#1b1a19;color:#faf9f5;font:16px sans-serif;padding:24px'>OmniRoute ne répond pas.<br>Retourne dans Chat et touche la pastille OmniRoute pour le démarrer.</body>", "text/html", "utf-8");
            }
        });
        dash.setVisibility(View.GONE);

        FrameLayout frame = new FrameLayout(this);
        frame.addView(web, new FrameLayout.LayoutParams(-1, -1));
        frame.addView(dash, new FrameLayout.LayoutParams(-1, -1));

        navBar = new LinearLayout(this);
        navBar.setOrientation(LinearLayout.HORIZONTAL);
        navBar.setGravity(Gravity.CENTER_VERTICAL);
        navBar.setPadding(dp(8), dp(8), dp(8), dp(8));
        navBar.addView(navItem(R.drawable.ic_chat, "Chat", 0));
        navBar.addView(navItem(R.drawable.ic_dash, "OmniRoute", 1));
        navBar.addView(navItem(R.drawable.ic_tune, "Réglages", 2));
        navWrap = new LinearLayout(this);
        navWrap.setPadding(dp(14), dp(8), dp(14), dp(8));
        navWrap.addView(navBar, new LinearLayout.LayoutParams(-1, -2));

        rootView = new LinearLayout(this);
        rootView.setOrientation(LinearLayout.VERTICAL);
        rootView.addView(frame, new LinearLayout.LayoutParams(-1, 0, 1));
        rootView.addView(navWrap, new LinearLayout.LayoutParams(-1, -2));
        setContentView(rootView);
        styleBar();
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

    private int dp(int v) { return (int) (v * getResources().getDisplayMetrics().density); }

    private LinearLayout navItem(int icon, String label, int idx) {
        LinearLayout it = new LinearLayout(this);
        it.setOrientation(LinearLayout.HORIZONTAL);
        it.setGravity(Gravity.CENTER);
        ImageView iv = new ImageView(this);
        iv.setImageResource(icon);
        TextView tv = new TextView(this);
        tv.setText(label);
        tv.setTextSize(14);
        tv.setSingleLine(true);
        tv.setTypeface(null, android.graphics.Typeface.BOLD);
        tv.setPadding(dp(8), 0, 0, 0);
        it.addView(iv, new LinearLayout.LayoutParams(dp(24), dp(24)));
        it.addView(tv);
        it.setOnClickListener(v -> select(idx));
        navItems[idx] = it; navIcons[idx] = iv; navLabels[idx] = tv;
        return it;
    }

    private void select(int i) {
        if (i == 2) {
            setTab(false);
            web.evaluateJavascript("location.hash='settings'", null);
        } else {
            web.evaluateJavascript("if(location.hash==='#settings')history.back()", null);
            showTab(i == 1);
        }
        paintNav(i);
    }

    private void showTab(boolean d) {
        if (d && (dash.getUrl() == null || dash.getUrl().startsWith("data:"))) dash.loadUrl("http://localhost:20128");
        setTab(d);
        paintNav(d ? 1 : (sel == 2 ? 2 : 0));
    }

    private void setTab(boolean d) {
        dash.setVisibility(d ? View.VISIBLE : View.GONE);
        web.setVisibility(d ? View.GONE : View.VISIBLE);
    }

    private void styleBar() {
        GradientDrawable g = new GradientDrawable();
        g.setCornerRadius(dp(34));
        g.setColor(Color.parseColor(dark ? "#2b2a28" : "#ebe5dc"));
        navBar.setBackground(g);
        int bg = Color.parseColor(dark ? "#1b1a19" : "#fbf8f3");
        rootView.setBackgroundColor(bg);
        navWrap.setBackgroundColor(bg);
        getWindow().setStatusBarColor(bg);
        getWindow().setNavigationBarColor(bg);
        int flags = 0;
        if (!dark) {
            flags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
            if (Build.VERSION.SDK_INT >= 26) flags |= View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        }
        getWindow().getDecorView().setSystemUiVisibility(flags);
        paintNav(sel);
    }

    private void paintNav(int i) {
        sel = i;
        TransitionManager.beginDelayedTransition(navBar);
        int on = Color.parseColor(dark ? "#f0ede8" : "#1e1b17"), off = Color.parseColor(dark ? "#b3ada5" : "#5f584f");
        for (int k = 0; k < 3; k++) {
            boolean s = k == i;
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(56), s ? 2.3f : 1f);
            lp.setMargins(dp(2), 0, dp(2), 0);
            navItems[k].setLayoutParams(lp);
            navLabels[k].setVisibility(s ? View.VISIBLE : View.GONE);
            navLabels[k].setTextColor(on);
            navIcons[k].setColorFilter(s ? on : off);
            GradientDrawable g = new GradientDrawable();
            g.setCornerRadius(dp(28));
            g.setColor(s ? ((accent & 0x00FFFFFF) | 0x66000000) : Color.TRANSPARENT);
            navItems[k].setBackground(g);
        }
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
            if (background) {
                int fl = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
                i.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT",
                    PendingIntent.getBroadcast(this, 0, new Intent(this, ResultReceiver.class), fl));
            }
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
        } catch (Exception e) {
            toast("Termux : " + e.getMessage());
        }
    }

    private void startServer() {
        startServer(prefs.getBoolean("visible", false));
    }

    private void startServer(boolean visible) {
        lastVisible = visible;
        ResultReceiver.last = "";
        if (visible) runTermux(BASH, new String[]{"-c", START_VIS}, false, null);
        else runTermux(BASH, new String[]{"-c", START_BG}, true, null);
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
                if (!up && hasPerm()) {
                    boolean vis = prefs.getBoolean("visible", false);
                    if (tick == 0) ui.post(() -> startServer(vis));
                    else if (tick == 8 && !vis) ui.post(() -> startServer(true));
                    else if (tick > 8 && tick % 30 == 0) ui.post(() -> startServer(vis));
                    tick++;
                }
                if (up) tick = 0;
                if (up && !connected) {
                    connected = true;
                    SharedPreferences.Editor ed = prefs.edit().putBoolean("ready", true);
                    if (lastVisible) ed.putBoolean("visible", true);
                    ed.apply();
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
        @JavascriptInterface public void showUrl(String u) {
            ui.post(() -> {
                try {
                    String h = Uri.parse(u).getHost();
                    if (!"localhost".equals(h) && !"127.0.0.1".equals(h)) return;
                    String cur = dash.getUrl();
                    if (cur == null || !cur.startsWith(u)) dash.loadUrl(u);
                    setTab(true);
                    paintNav(1);
                } catch (Exception e) { }
            });
        }
        @JavascriptInterface public String dynamicColor() {
            if (Build.VERSION.SDK_INT < 31) return "";
            return String.format("#%06X", 0xFFFFFF & getColor(android.R.color.system_accent1_500));
        }
        @JavascriptInterface public void setStyle(String hex, boolean d) {
            ui.post(() -> {
                try { accent = Color.parseColor(hex); } catch (Exception e) { }
                dark = d;
                styleBar();
            });
        }
        @JavascriptInterface public void onRoute(boolean settings) {
            ui.post(() -> {
                if (settings) { setTab(false); paintNav(2); }
                else if (sel == 2) paintNav(0);
            });
        }
        @JavascriptInterface public void showDashboard() { ui.post(() -> showTab(true)); }
        @JavascriptInterface public void start() { ui.post(() -> startServer()); }
        @JavascriptInterface public void startMode(boolean visible) { ui.post(() -> startServer(visible)); }
        @JavascriptInterface public boolean isReady() { return prefs.getBoolean("ready", false); }
        @JavascriptInterface public String lastError() { return ResultReceiver.last; }
        @JavascriptInterface public void resetSetup() { prefs.edit().clear().apply(); ResultReceiver.last = ""; }
    }
}
