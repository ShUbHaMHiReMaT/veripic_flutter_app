# Razorpay checkout. Release builds are shrunk with R8, which otherwise strips
# the classes Razorpay reaches by reflection and the payment sheet crashes or
# never reports back. Rules from Razorpay's Android integration guide.
-keepattributes *Annotation*
-dontwarn com.razorpay.**
-keep class com.razorpay.** {*;}
-optimizations !method/inlining/
-keepclasseswithmembers class * {
  public void onPayment*(...);
}
