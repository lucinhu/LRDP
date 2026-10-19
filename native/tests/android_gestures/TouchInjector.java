/* Test-only shell-UID input driver for LRDP's private Android emulator.
 * Never included in the application APK. Coordinates are Android logical display pixels. */
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Method;
import org.json.JSONArray;
import org.json.JSONObject;

public final class TouchInjector {
    private final Object manager;
    private final Method inject;
    private float[][] points;
    private long downTime;

    private TouchInjector() throws Exception {
        // API36's deprecated InputManager singleton requires an Application.
        // Its process-global binder interface also serves Android's shell tools.
        Class<?> type;
        try {
            type = Class.forName("android.hardware.input.InputManagerGlobal");
        } catch (ClassNotFoundException legacy) {
            // Older releases expose the same shell injection API on this class.
            type = Class.forName("android.hardware.input.InputManager");
        }
        manager = type.getMethod("getInstance").invoke(null);
        inject = type.getMethod("injectInputEvent", InputEvent.class, int.class);
    }

    private static float[][] points(JSONArray array) throws Exception {
        if (array.length() < 1 || array.length() > 2) throw new IllegalArgumentException("1 or 2 pointers required");
        float[][] result = new float[array.length()][2];
        for (int i = 0; i < array.length(); i++) {
            JSONArray point = array.getJSONArray(i);
            for (int j = 0; j < 2; j++) {
                double value = point.getDouble(j);
                if (!Double.isFinite(value) || value < 0 || value > 10000) throw new IllegalArgumentException("Invalid coordinate");
                result[i][j] = (float)value;
            }
        }
        return result;
    }

    private void emit(int action, float[][] coordinates, boolean mouse) throws Exception {
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[coordinates.length];
        MotionEvent.PointerCoords[] positions = new MotionEvent.PointerCoords[coordinates.length];
        for (int i = 0; i < coordinates.length; i++) {
            properties[i] = new MotionEvent.PointerProperties();
            properties[i].id = i;
            properties[i].toolType = mouse ? MotionEvent.TOOL_TYPE_MOUSE : MotionEvent.TOOL_TYPE_FINGER;
            positions[i] = new MotionEvent.PointerCoords();
            positions[i].x = coordinates[i][0]; positions[i].y = coordinates[i][1];
            positions[i].pressure = mouse ? 0 : 1; positions[i].size = 1;
        }
        MotionEvent event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action,
            coordinates.length, properties, positions, 0, 0, 1, 1, 0, 0,
            mouse ? InputDevice.SOURCE_MOUSE : InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            // WAIT_FOR_FINISH: do not acknowledge a frame the dispatcher rejected.
            if (!Boolean.TRUE.equals(inject.invoke(manager, event, 2))) throw new IllegalStateException("Input dispatch rejected");
        } finally { event.recycle(); }
    }

    private void down(float[][] coordinates) throws Exception {
        if (points != null) throw new IllegalStateException("Previous gesture is still held");
        downTime = SystemClock.uptimeMillis();
        emit(MotionEvent.ACTION_DOWN, new float[][] { coordinates[0] }, false);
        if (coordinates.length == 2) {
            SystemClock.sleep(8);
            emit(MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), coordinates, false);
        }
        points = coordinates;
    }

    private void up() throws Exception {
        if (points == null) throw new IllegalStateException("No held gesture");
        if (points.length == 2) {
            emit(MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), points, false);
            SystemClock.sleep(8);
        }
        emit(MotionEvent.ACTION_UP, new float[][] { points[0] }, false);
        points = null;
    }

    private void cancel() throws Exception {
        if (points != null) emit(MotionEvent.ACTION_CANCEL, points, false);
        points = null;
    }

    private void move(float[][] target, int duration) throws Exception {
        if (points == null || target.length != points.length) throw new IllegalStateException("Pointer count changed");
        float[][] start = points;
        long began = SystemClock.uptimeMillis();
        int steps = Math.max(2, duration / 16);
        for (int step = 1; step <= steps; step++) {
            long deadline = began + (long)duration * step / steps;
            SystemClock.sleep(Math.max(0, deadline - SystemClock.uptimeMillis()));
            float[][] frame = new float[start.length][2];
            for (int i = 0; i < start.length; i++) for (int j = 0; j < 2; j++)
                frame[i][j] = start[i][j] + (target[i][j] - start[i][j]) * step / steps;
            emit(MotionEvent.ACTION_MOVE, frame, false);
            points = frame;
        }
    }

    private void command(JSONObject command) throws Exception {
        String action = command.getString("action");
        int duration = command.optInt("duration", 400);
        if (duration < 20 || duration > 2000) throw new IllegalArgumentException("Invalid duration");
        switch (action) {
            case "text": {
                // ASCII test credentials travel over stdin, never argv/logs.
                String value = command.getString("value");
                if (value.length() > 256 || !value.chars().allMatch(v -> v >= 32 && v < 127))
                    throw new IllegalArgumentException("Expected short ASCII input");
                KeyEvent[] events = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(value.toCharArray());
                if (events == null) throw new IllegalArgumentException("Input cannot be mapped");
                for (KeyEvent event : events)
                    if (!Boolean.TRUE.equals(inject.invoke(manager, event, 2))) throw new IllegalStateException("Key dispatch rejected");
                break;
            }
            case "tap":
                down(points(command.getJSONArray("from"))); SystemClock.sleep(duration); up(); break;
            case "swipe":
                down(points(command.getJSONArray("from")));
                move(points(command.getJSONArray("to")), duration); up(); break;
            case "drag": {
                float[][] start = points(command.getJSONArray("from"));
                down(start); SystemClock.sleep(65); up(); SystemClock.sleep(90);
                down(start); SystemClock.sleep(190);
                move(points(command.getJSONArray("to")), duration);
                if (!command.optBoolean("hold", false)) up();
                break;
            }
            case "aux-tap": {
                if (points == null || points.length != 1) throw new IllegalStateException("One pointer must be held");
                float[][] pair = new float[][] {points[0], points(command.getJSONArray("from"))[0]};
                emit(MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), pair, false);
                SystemClock.sleep(duration);
                emit(MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), pair, false);
                break;
            }
            case "up": up(); break;
            case "cancel": cancel(); break;
            case "hover":
                if (points != null) throw new IllegalStateException("Touch is held");
                downTime = SystemClock.uptimeMillis();
                emit(MotionEvent.ACTION_HOVER_MOVE, points(command.getJSONArray("from")), true); break;
            default: throw new IllegalArgumentException("Unknown action");
        }
    }

    public static void main(String[] args) throws Exception {
        TouchInjector driver = new TouchInjector();
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
        System.out.println("{\"ready\":true}"); System.out.flush();
        try {
            String line;
            while ((line = input.readLine()) != null) {
                driver.command(new JSONObject(line));
                System.out.println("{\"ok\":true}"); System.out.flush();
            }
        } finally { driver.cancel(); }
    }
}
