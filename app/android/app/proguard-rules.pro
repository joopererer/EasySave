# ProGuard / R8 keep rules for EasySave

# Keep NativeLog and its members for background_downloader reflection and diagnostic logging
-keep class com.james.easysave.NativeLog {
    public static final com.james.easysave.NativeLog INSTANCE;
    public void i(java.lang.String, java.lang.String);
    public void w(java.lang.String, java.lang.String, java.lang.Throwable);
    public void e(java.lang.String, java.lang.String, java.lang.Throwable);
}
-keepclassmembers class com.james.easysave.NativeLog {
    *;
}

