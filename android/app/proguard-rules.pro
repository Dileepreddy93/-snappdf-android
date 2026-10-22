# PDFBox loads resources and some classes reflectively.
-keep class com.tom_roush.pdfbox.** { *; }
-keep class com.tom_roush.fontbox.** { *; }
-keep class com.tom_roush.harmony.** { *; }
-dontwarn com.tom_roush.**
-dontwarn org.bouncycastle.**
-dontwarn javax.xml.bind.**
-dontwarn com.gemalto.jp2.**
