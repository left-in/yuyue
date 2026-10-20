# UniFFI bindings reach the core through JNA, by reflection.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class uniffi.yuyue_core.** { *; }
-dontwarn java.awt.**
