# pdfbox-android (document text extraction) can decode JPEG 2000 images through an optional
# library that Child Assist does not ship; text extraction never needs it.
-dontwarn com.gemalto.jp2.JP2Decoder
