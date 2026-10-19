/* Test-only IME for the owned emulator. Never packaged in LRDP. */
package dev.lrdp.fixture.ime;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.inputmethodservice.InputMethodService;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.TextView;

public final class FixtureIme extends InputMethodService {
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            InputConnection input = getCurrentInputConnection();
            if (input == null) { setResultCode(0); return; }
            String action = intent.getStringExtra("operation");
            String text = intent.getStringExtra("text");
            if (text == null) text = "";
            if (text.length() > 256) { setResultCode(0); return; }
            boolean ok = false;
            if ("commit".equals(action)) ok = input.commitText(text, 1);
            else if ("compose".equals(action)) ok = input.setComposingText(text, 1);
            else if ("finish".equals(action)) ok = input.finishComposingText();
            else if ("delete".equals(action)) ok = input.deleteSurroundingText(1, 0);
            else if ("enter".equals(action)) ok = input.performEditorAction(EditorInfo.IME_ACTION_DONE);
            setResultCode(ok ? 1 : 0);
        }
    };
    @Override public void onCreate() {
        super.onCreate();
        IntentFilter filter = new IntentFilter("dev.lrdp.fixture.IME");
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(receiver, filter);
        }
    }
    @Override public boolean onEvaluateInputViewShown() { return true; }
    @Override public View onCreateInputView() {
        TextView view = new TextView(this);
        view.setText("LRDP isolated IME fixture");
        view.setTextColor(0xff182d28); view.setBackgroundColor(0xffeeeeee);
        // InputMethodService supplies its own LayoutParams. A real minimum
        // keeps the test keyboard at 160dp instead of one line of text.
        view.setMinHeight((int)(160 * getResources().getDisplayMetrics().density));
        view.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
            (int)(160 * getResources().getDisplayMetrics().density)));
        return view;
    }
    @Override public void onDestroy() { unregisterReceiver(receiver); super.onDestroy(); }
}
