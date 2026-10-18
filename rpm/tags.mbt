// Tag numbers used by this package (see rpm's rpmtag.h).

///|
const TAG_I18N_TABLE : Int32 = 100

///|
const TAG_NAME : Int32 = 1000

///|
const TAG_VERSION : Int32 = 1001

///|
const TAG_RELEASE : Int32 = 1002

///|
const TAG_EPOCH : Int32 = 1003

///|
const TAG_SUMMARY : Int32 = 1004

///|
const TAG_DESCRIPTION : Int32 = 1005

///|
const TAG_BUILDTIME : Int32 = 1006

///|
const TAG_BUILDHOST : Int32 = 1007

///|
const TAG_SIZE : Int32 = 1009

///|
const TAG_VENDOR : Int32 = 1011

///|
const TAG_LICENSE : Int32 = 1014

///|
const TAG_PACKAGER : Int32 = 1015

///|
const TAG_GROUP : Int32 = 1016

///|
const TAG_URL : Int32 = 1020

///|
const TAG_OS : Int32 = 1021

///|
const TAG_ARCH : Int32 = 1022

///|
const TAG_PREIN : Int32 = 1023

///|
const TAG_POSTIN : Int32 = 1024

///|
const TAG_PREUN : Int32 = 1025

///|
const TAG_POSTUN : Int32 = 1026

///|
const TAG_FILESIZES : Int32 = 1028

///|
const TAG_FILEMODES : Int32 = 1030

///|
const TAG_FILERDEVS : Int32 = 1033

///|
const TAG_FILEMTIMES : Int32 = 1034

///|
const TAG_FILEDIGESTS : Int32 = 1035

///|
const TAG_FILELINKTOS : Int32 = 1036

///|
const TAG_FILEFLAGS : Int32 = 1037

///|
const TAG_FILEUSERNAME : Int32 = 1039

///|
const TAG_FILEGROUPNAME : Int32 = 1040

///|
const TAG_SOURCERPM : Int32 = 1044

///|
const TAG_FILEVERIFYFLAGS : Int32 = 1045

///|
const TAG_PROVIDENAME : Int32 = 1047

///|
const TAG_REQUIREFLAGS : Int32 = 1048

///|
const TAG_REQUIRENAME : Int32 = 1049

///|
const TAG_REQUIREVERSION : Int32 = 1050

///|
const TAG_CONFLICTFLAGS : Int32 = 1053

///|
const TAG_CONFLICTNAME : Int32 = 1054

///|
const TAG_CONFLICTVERSION : Int32 = 1055

///|
const TAG_PREINPROG : Int32 = 1085

///|
const TAG_POSTINPROG : Int32 = 1086

///|
const TAG_PREUNPROG : Int32 = 1087

///|
const TAG_POSTUNPROG : Int32 = 1088

///|
const TAG_OBSOLETENAME : Int32 = 1090

///|
const TAG_FILEDEVICES : Int32 = 1095

///|
const TAG_FILEINODES : Int32 = 1096

///|
const TAG_FILELANGS : Int32 = 1097

///|
const TAG_PROVIDEFLAGS : Int32 = 1112

///|
const TAG_PROVIDEVERSION : Int32 = 1113

///|
const TAG_OBSOLETEFLAGS : Int32 = 1114

///|
const TAG_OBSOLETEVERSION : Int32 = 1115

///|
const TAG_DIRINDEXES : Int32 = 1116

///|
const TAG_BASENAMES : Int32 = 1117

///|
const TAG_DIRNAMES : Int32 = 1118

///|
const TAG_PAYLOADFORMAT : Int32 = 1124

///|
const TAG_PAYLOADCOMPRESSOR : Int32 = 1125

///|
const TAG_PAYLOADFLAGS : Int32 = 1126

///|
const TAG_FILEDIGESTALGO : Int32 = 5011

///|
const TAG_RECOMMENDNAME : Int32 = 5046

///|
const TAG_RECOMMENDVERSION : Int32 = 5047

///|
const TAG_RECOMMENDFLAGS : Int32 = 5048

///|
const TAG_SUGGESTNAME : Int32 = 5049

///|
const TAG_SUGGESTVERSION : Int32 = 5050

///|
const TAG_SUGGESTFLAGS : Int32 = 5051

///|
const TAG_PAYLOADDIGEST : Int32 = 5092

///|
const TAG_PAYLOADDIGESTALGO : Int32 = 5093

// Signature header tags.

///|
const SIG_SIZE : Int32 = 1000

///|
const SIG_PAYLOADSIZE : Int32 = 1007

///|
const SIG_SHA256 : Int32 = 273

///|
/// Region tags: signature header and main header.
const REGION_SIGNATURE : Int32 = 62

///|
const REGION_IMMUTABLE : Int32 = 63

// RPMSENSE flags.

///|
const SENSE_LESS : Int32 = 2

///|
const SENSE_GREATER : Int32 = 4

///|
const SENSE_EQUAL : Int32 = 8

///|
const SENSE_RPMLIB : Int32 = 16777216

///|
/// File flag: configuration file.
const FILE_CONFIG : Int32 = 1

///|
/// Digest algorithm number of SHA-256 (PGPHASHALGO_SHA256).
const DIGEST_SHA256 : Int32 = 8
