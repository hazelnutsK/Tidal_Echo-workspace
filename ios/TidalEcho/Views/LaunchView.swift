import SwiftUI
import UIKit

/// 开屏：Aquila 从左往右一扫就出来，扫完 i 上落一颗心，停一小拍就走。
///
/// 字是 Melvin and Emily 的 ss02 那套字形（她 2026-09-27 定的）。这套字的 i 本来就没有点，
/// 心正好补上。仓库是公开的，这款字又写着 All rights reserved，所以不打包字体文件，
/// 只把排好的这六个字母存成一条轮廓路径。
///
/// 整幅画面是**时间的纯函数**（TimelineView + Canvas），任何一帧都可复现。
struct LaunchView: View {
    let theme: EchoTheme

    /// 从开始扫字到开屏该让位的时刻：扫字 0.8s，心落 0.18s，再停 0.15s。
    /// RootView 按这个数放行，别在那边另写一个。
    static let handoff: Duration = .milliseconds(Int(Beat.exit * 1000))

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()

            if reduceMotion {
                Canvas { context, size in
                    Signature(theme: theme, size: size).draw(into: context, t: Beat.rest)
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        Signature(theme: theme, size: size)
                            .draw(into: context, t: timeline.date.timeIntervalSince(start))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tidal Echo 正在启动")
        .onAppear { start = Date() }
    }
}

// MARK: - 登录页的签名

/// 开屏最后一帧，原样搬到登录页：同一处、同一颗心。开屏淡出时它就停在原地，
/// 登录页再把它往上托。只画字和心，不画底。
struct LaunchSignature: View {
    let theme: EchoTheme

    /// 字形中心在整屏高度上的位置（缩放用的锚点）。
    static let anchorFraction: CGFloat = 0.478

    static func anchorY(in size: CGSize) -> CGFloat { size.height * anchorFraction }

    /// 签名墨迹的底边离字形中心多远（未缩放），登录页的玻璃从这下面开始。
    static func bottomDrop(in size: CGSize) -> CGFloat {
        Mark.layout(in: size).rect.maxY - anchorY(in: size) + 8
    }

    var body: some View {
        Canvas { context, size in
            Signature(theme: theme, size: size, backdrop: false).draw(into: context, t: Beat.rest)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aquila")
    }
}

// MARK: - 时间轴

private enum Beat {
    /// 她 2026-09-27 在预览里定的：扫字 0.8s，心落下后停 0.15s。
    static let sweep = 0.0...0.8
    static let heart = 0.82...1.0
    static let hold = 0.15
    static let exit = heart.upperBound + hold

    /// reduceMotion 和登录页用的静止帧：全部写完。
    static let rest: Double = 9
}

private func clamp01(_ x: Double) -> Double { x < 0 ? 0 : (x > 1 ? 1 : x) }
private func ramp(_ t: Double, _ range: ClosedRange<Double>) -> Double {
    clamp01((t - range.lowerBound) / (range.upperBound - range.lowerBound))
}
private func easeInOut(_ x: Double) -> Double {
    x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
/// 心落定时轻轻回弹一下，比原来那版收着些。
private func easeOutBack(_ x: Double) -> Double {
    1 + 1.6 * pow(x - 1, 3) + 0.6 * pow(x - 1, 2)
}

// MARK: - 字形

private enum Mark {
    /// 墨迹宽度（pt）。她定的 320，窄屏上两边至少留 20。
    static let width: CGFloat = 320

    /// 轮廓的坐标系：字体单位，墨框左上角为原点，y 向下。
    static let inkSize = CGSize(width: 8784, height: 1813)

    /// 心落在 i 那一竖正上方，按墨框比例量的（和她看过的预览同一个位置）。
    static let heartAt = CGPoint(x: 0.627, y: 0.225)
    static let heartWidth: CGFloat = 7.5

    /// 由 harfbuzz 按 ss02 排好 "Aquila" 后导出；只有 M / L / C / Q / Z 五种命令，全是绝对坐标。
    private static let outline = "M608 1695C614 1696 621 1695 627 1692C633 1689 636 1684 635 1679C634 1673 629 1671 624 1670L621 1670C611 1669 606 1665 605 1654C604 1647 604 1639 606 1631C609 1608 615 1585 622 1563C640 1508 662 1455 685 1402C716 1330 749 1260 784 1191C821 1118 864 1050 909 982C961 905 1016 831 1073 758C1077 753 1081 750 1088 750C1149 750 1209 749 1270 746C1299 744 1327 742 1355 737C1364 735 1373 733 1382 730C1393 725 1401 717 1406 706C1408 704 1408 701 1405 699C1403 697 1400 698 1398 700C1398 701 1397 702 1396 703C1389 712 1380 717 1368 720C1353 724 1338 726 1322 727C1277 731 1232 733 1187 734L1106 734C1103 734 1098 736 1096 733C1094 729 1099 726 1101 724C1135 681 1171 638 1207 597C1241 558 1275 519 1310 481C1385 398 1463 316 1541 236C1579 196 1619 157 1657 117C1671 101 1686 85 1699 68C1706 59 1712 49 1716 38C1723 17 1711 0 1688 1C1681 2 1673 3 1665 5C1635 14 1606 27 1578 42C1502 82 1427 126 1355 172C1206 269 1063 374 922 481C828 553 736 628 645 704C638 709 632 711 623 711C582 711 540 714 499 719C451 726 404 736 358 751C309 767 263 790 224 824C211 835 198 847 189 861C185 868 182 875 181 884C181 887 182 890 186 891C189 891 190 889 191 886C198 869 210 857 223 845C261 810 306 785 356 768C436 740 520 730 605 727C606 727 607 727 609 728C612 728 613 729 611 731L605 737L566 769C474 846 382 923 286 995C239 1030 191 1064 139 1093C118 1104 97 1115 74 1118C49 1122 37 1110 34 1089C31 1074 33 1060 36 1046C39 1030 43 1014 51 999C53 994 56 989 63 987C68 987 69 982 66 977C63 970 54 968 46 972C39 975 34 981 31 987C10 1020 0 1056 6 1096C11 1123 31 1147 66 1145C86 1144 105 1138 123 1130C160 1112 194 1090 228 1066C299 1016 365 961 432 905C499 849 567 792 634 735C640 729 646 727 655 727C676 729 698 729 719 731C760 733 801 737 842 740C880 743 918 746 956 748C973 749 990 749 1008 750C1013 750 1014 751 1011 756L1004 765C950 836 898 909 850 985C815 1040 782 1097 753 1156C728 1207 704 1259 681 1311C656 1366 633 1422 613 1479C597 1524 581 1570 574 1617C572 1633 571 1649 575 1665C580 1681 590 1692 608 1695ZM1018 734C1009 733 1000 733 991 733C952 732 914 728 876 726C837 723 798 719 759 716C731 714 702 713 674 712C671 711 667 713 666 710C665 707 669 705 671 704C765 625 860 547 958 472C1059 395 1161 319 1267 248C1352 190 1439 135 1530 88C1565 69 1601 52 1639 39C1650 36 1661 33 1672 31C1674 30 1675 31 1676 31C1677 32 1676 34 1675 35L1669 42C1639 75 1607 105 1576 135C1486 223 1398 313 1312 405C1270 450 1229 495 1188 541C1137 599 1086 659 1039 720C1037 722 1035 724 1034 727C1030 732 1025 735 1018 734ZM1898 1805C1904 1802 1910 1799 1916 1794C1932 1783 1946 1769 1959 1755C2020 1687 2069 1612 2108 1530C2143 1459 2171 1386 2180 1307C2182 1281 2182 1256 2175 1231C2172 1223 2174 1218 2179 1211C2217 1162 2256 1115 2297 1068C2308 1055 2320 1044 2334 1036C2464 957 2597 883 2731 812C2752 801 2772 790 2792 777C2795 776 2797 774 2799 772C2801 770 2802 768 2800 766C2799 764 2797 763 2795 764C2792 765 2790 767 2788 768C2775 774 2763 781 2751 788C2677 824 2606 863 2534 903C2479 934 2423 965 2368 995C2366 996 2364 999 2362 997C2360 995 2364 994 2365 992C2366 990 2367 989 2369 988C2431 922 2496 858 2561 795C2584 772 2607 750 2630 728C2636 722 2643 716 2647 708C2650 702 2650 696 2646 691C2642 687 2636 685 2629 688C2625 690 2621 693 2617 696C2611 699 2606 703 2600 706C2597 708 2595 708 2592 704C2585 690 2573 686 2558 686C2547 686 2537 689 2526 692C2497 701 2469 714 2442 729C2367 754 2292 780 2217 804C2101 842 1984 876 1863 894C1792 905 1721 913 1649 907C1620 904 1592 900 1565 891C1544 885 1525 877 1509 863C1475 833 1450 798 1438 755C1430 727 1432 701 1451 678C1453 675 1453 672 1455 670C1437 682 1431 700 1429 720C1427 736 1430 751 1436 766C1446 795 1462 820 1481 844C1502 871 1528 888 1559 899C1590 910 1622 915 1655 917C1710 921 1765 919 1819 912C1905 901 1990 884 2074 861C2182 831 2288 794 2394 757L2403 754C2399 756 2396 759 2392 761C2377 772 2362 785 2349 799C2343 805 2337 812 2335 821C2330 834 2338 847 2353 848C2360 849 2366 848 2373 847C2388 843 2401 837 2415 831C2454 813 2491 792 2528 771C2532 768 2536 765 2541 765C2538 772 2531 775 2526 780C2432 866 2343 958 2260 1056C2254 1063 2247 1069 2239 1075C2194 1104 2151 1136 2109 1170C2105 1173 2101 1176 2098 1180C2093 1187 2096 1194 2104 1197C2109 1198 2113 1198 2118 1198C2123 1198 2128 1199 2133 1201C2140 1205 2141 1207 2136 1213C2136 1215 2135 1216 2134 1217C2097 1267 2061 1319 2027 1372C1974 1454 1926 1539 1888 1630C1873 1667 1860 1705 1854 1745C1853 1758 1852 1771 1856 1784C1862 1804 1879 1813 1898 1805ZM2370 826C2368 826 2365 827 2364 825C2363 823 2365 821 2366 820C2368 817 2370 815 2372 813C2417 774 2467 742 2523 722C2534 718 2545 715 2557 715L2563 715C2566 716 2570 717 2571 721C2572 726 2567 726 2565 728C2516 757 2468 785 2417 810C2403 816 2389 822 2374 825ZM2152 1190C2148 1187 2143 1185 2139 1183C2129 1178 2129 1178 2138 1171C2157 1157 2177 1143 2196 1128C2197 1127 2199 1125 2201 1127C2201 1127 2200 1130 2199 1131L2157 1185C2156 1187 2154 1189 2152 1190ZM1891 1786C1883 1789 1880 1788 1877 1780C1873 1767 1876 1754 1879 1742C1886 1704 1900 1669 1915 1635C1957 1539 2011 1450 2069 1364C2094 1326 2120 1290 2147 1254C2148 1251 2150 1249 2152 1246C2153 1245 2154 1243 2156 1243C2160 1244 2159 1247 2159 1249C2162 1260 2161 1272 2162 1282C2162 1327 2151 1369 2137 1411C2102 1518 2047 1614 1977 1702C1957 1727 1937 1752 1913 1772C1906 1778 1899 1783 1891 1786ZM4078 1054C4087 1052 4095 1047 4102 1043C4122 1028 4141 1012 4158 994C4198 955 4234 913 4272 873L4343 796C4352 787 4361 777 4371 769C4373 767 4376 765 4374 762C4372 759 4368 761 4366 763C4362 766 4357 770 4353 774C4339 787 4325 801 4312 816C4266 864 4222 913 4175 960C4154 980 4133 1000 4110 1018C4101 1025 4093 1031 4082 1035C4070 1041 4065 1037 4066 1023C4067 1015 4068 1007 4071 1000C4083 963 4102 929 4122 896C4144 858 4171 822 4196 786C4206 771 4217 756 4226 741C4229 734 4232 727 4234 720C4236 705 4224 695 4210 699C4204 701 4200 703 4195 707L4157 731C4114 760 4072 790 4028 817C4011 827 3994 837 3976 845C3968 848 3960 851 3952 853C3939 855 3936 853 3940 840C3944 830 3950 820 3955 811C3975 779 4000 750 4026 723L4038 709C4041 705 4041 700 4038 696C4035 691 4030 690 4025 692C4021 693 4018 695 4015 697C4010 697 4005 698 4000 699C3948 712 3896 714 3843 713C3802 712 3762 708 3721 703L3582 688C3543 684 3504 679 3465 676C3407 673 3349 671 3291 675C3239 679 3187 685 3137 696C3057 715 2979 742 2903 773C2881 783 2859 793 2838 805C2826 812 2813 820 2803 830C2791 842 2784 855 2786 872C2786 874 2787 877 2789 878C2792 879 2793 876 2793 874C2794 851 2809 836 2827 824C2847 811 2868 801 2889 791C2948 766 3009 746 3070 727C3123 711 3178 700 3233 693C3313 683 3393 683 3473 689C3543 694 3614 702 3684 712C3737 718 3790 724 3844 727C3894 729 3944 724 3993 715C3978 730 3964 746 3951 764C3937 783 3925 803 3918 825C3915 834 3913 842 3914 851C3915 866 3924 875 3939 875C3953 875 3965 871 3976 866C4000 855 4023 841 4045 826C4084 802 4121 774 4160 751L4183 737C4185 736 4186 735 4187 737C4188 738 4187 739 4186 740L4182 746C4161 774 4141 802 4122 831C4094 874 4071 920 4055 968C4050 985 4046 1002 4045 1017C4045 1024 4045 1029 4047 1034C4051 1051 4061 1057 4078 1054ZM4762 958C4819 958 4879 953 4939 944C5029 930 5116 908 5201 875C5255 853 5307 828 5356 798C5343 819 5332 842 5325 866C5321 879 5319 892 5319 906L5319 911C5320 946 5341 963 5375 957C5401 952 5425 941 5448 928C5493 903 5536 877 5578 848C5607 829 5635 809 5660 786C5663 784 5668 782 5665 778C5662 774 5658 779 5656 781C5618 812 5577 839 5535 864C5501 885 5467 906 5430 923C5415 930 5398 935 5381 938C5353 943 5342 933 5346 904C5350 880 5358 857 5370 835C5381 813 5395 792 5409 772C5412 768 5416 764 5417 758C5418 754 5418 750 5414 747C5410 744 5406 744 5402 746C5397 749 5393 754 5389 758C5384 762 5380 766 5377 771C5289 828 5195 869 5095 898C5003 924 4908 940 4812 944C4764 946 4715 946 4666 941C4627 937 4589 932 4552 922C4515 913 4479 900 4445 880C4426 869 4409 855 4395 838C4376 815 4368 788 4374 758C4378 739 4387 723 4399 708C4415 687 4435 672 4458 660C4499 639 4541 623 4586 615C4600 613 4613 612 4624 623C4625 624 4627 625 4627 623C4628 622 4627 620 4627 619C4622 612 4615 610 4607 609C4595 607 4583 608 4571 611C4528 621 4486 635 4446 656C4421 670 4399 689 4383 713C4347 764 4353 821 4399 864C4416 880 4436 892 4457 902C4490 919 4525 930 4561 939C4626 953 4692 958 4762 958ZM5451 675L5456 675C5463 673 5471 659 5471 652C5471 645 5465 640 5459 641C5451 642 5445 646 5442 654C5439 660 5445 673 5451 675ZM6714 1223C6731 1226 6747 1223 6763 1218C6793 1209 6821 1194 6847 1177C6901 1144 6950 1104 6998 1063C7071 1001 7141 936 7211 871C7244 841 7277 810 7308 779C7310 777 7312 775 7314 772C7316 771 7315 769 7314 767C7312 766 7310 766 7309 767C7308 769 7307 770 7306 771C7244 831 7181 888 7117 945C7048 1009 6977 1071 6900 1126C6866 1151 6830 1174 6790 1191C6771 1198 6751 1205 6730 1205C6708 1204 6697 1195 6692 1173C6688 1151 6692 1130 6698 1109C6708 1073 6724 1040 6741 1008C6785 925 6839 849 6897 776C6908 762 6920 751 6937 745C6940 744 6943 742 6947 740C7058 683 7161 614 7256 533C7292 502 7327 469 7356 432C7364 422 7372 411 7376 399C7386 374 7373 356 7346 358C7344 358 7342 359 7340 359C7327 361 7315 366 7303 371C7264 387 7227 408 7193 433C7121 486 7055 546 6994 610C6951 654 6911 700 6873 748L6836 760C6733 795 6630 827 6524 850C6451 866 6378 879 6304 890C6245 898 6185 903 6126 905C6069 908 6013 905 5957 897C5906 890 5858 878 5811 857C5780 844 5751 826 5726 802C5689 767 5671 724 5670 673C5669 634 5679 597 5695 562C5712 523 5735 488 5762 455C5797 413 5838 377 5881 344C5971 277 6069 226 6174 191C6310 145 6448 113 6591 101C6617 99 6642 100 6667 107C6676 109 6684 113 6690 120C6695 127 6695 134 6693 142C6693 143 6694 144 6695 145C6696 144 6698 144 6698 143C6703 130 6701 119 6691 110C6683 103 6674 100 6664 98C6650 95 6636 93 6622 92C6580 91 6538 96 6496 103C6418 114 6342 131 6266 151C6161 178 6060 218 5965 273C5894 314 5828 363 5772 424C5733 465 5701 510 5680 563C5663 601 5655 641 5657 684C5660 732 5678 774 5712 809C5732 830 5756 847 5781 860C5810 876 5841 887 5873 896C5944 916 6017 921 6091 921C6164 921 6237 914 6309 904C6408 890 6505 869 6601 844C6689 822 6775 790 6862 762C6839 792 6817 823 6795 854C6756 913 6721 974 6695 1039C6680 1075 6669 1111 6668 1154C6668 1162 6669 1175 6673 1187C6681 1206 6694 1219 6714 1223ZM6954 711C6953 711 6953 709 6954 709C6955 707 6956 706 6957 705C7034 619 7115 539 7207 469C7234 448 7262 429 7291 412C7304 404 7317 398 7330 392C7335 390 7340 389 7344 387C7347 387 7350 385 7352 387C7354 390 7352 393 7351 396C7348 400 7345 405 7343 409C7339 415 7335 420 7330 426C7301 462 7267 494 7231 524C7149 595 7058 654 6964 707C6961 709 6958 710 6956 711ZM8425 1044C8436 1042 8446 1037 8456 1032C8486 1017 8514 998 8540 977C8595 934 8649 888 8703 842C8727 821 8751 801 8773 778L8782 768C8783 766 8784 763 8782 762C8780 759 8777 760 8775 762C8771 766 8767 770 8762 774C8696 831 8629 886 8560 940C8527 966 8493 990 8455 1010C8444 1015 8433 1020 8422 1023C8411 1025 8406 1022 8403 1012C8401 1009 8401 1005 8400 1002C8398 987 8400 973 8404 959C8418 910 8438 863 8464 818C8480 791 8498 766 8515 739C8518 734 8522 728 8523 721C8525 714 8524 709 8519 705C8514 700 8508 700 8502 703C8498 705 8495 708 8492 710C8462 734 8431 757 8399 777C8396 780 8392 786 8387 783C8384 781 8388 775 8390 771C8395 750 8378 734 8361 734C8350 734 8341 736 8332 741C8332 741 8331 741 8331 742C8300 739 8269 743 8239 750C8169 765 8102 789 8038 817C7971 846 7906 877 7840 907C7765 941 7689 972 7609 993C7565 1005 7520 1015 7473 1014L7451 1014C7424 1012 7397 1007 7372 995C7355 988 7341 977 7330 962C7316 941 7315 920 7327 898C7334 886 7344 876 7355 868C7365 861 7376 854 7387 847C7389 846 7391 845 7389 842C7388 842 7385 841 7384 842C7357 855 7331 871 7317 900C7305 923 7306 946 7321 968C7330 981 7341 991 7354 999C7368 1007 7382 1013 7398 1017C7432 1026 7466 1028 7501 1025C7544 1021 7586 1012 7627 1000C7701 980 7771 951 7841 920C7911 888 7980 854 8051 825C8112 799 8174 777 8239 762C8264 756 8288 751 8313 751C8288 766 8264 784 8244 807C8234 817 8225 830 8221 844C8215 867 8228 884 8251 885C8266 886 8279 881 8292 874C8314 863 8335 849 8356 835C8388 814 8419 791 8450 768C8452 767 8455 763 8456 765C8459 767 8455 769 8454 772C8453 773 8452 774 8452 775C8428 812 8408 850 8394 892C8384 922 8375 952 8374 984C8374 997 8375 1009 8380 1020C8388 1041 8404 1049 8425 1044ZM8260 855C8255 855 8255 853 8256 850C8258 848 8259 845 8261 843C8285 816 8311 794 8342 777L8345 775C8364 766 8366 767 8373 787C8374 792 8374 795 8369 797C8339 816 8310 836 8277 850C8272 853 8266 854 8260 855Z"

    static let path: Path = parse(outline)

    struct Layout {
        let rect: CGRect
        let transform: CGAffineTransform
    }

    static func layout(in size: CGSize) -> Layout {
        let w = min(width, size.width - 40)
        let s = w / inkSize.width
        let h = inkSize.height * s
        let rect = CGRect(
            x: (size.width - w) / 2,
            y: size.height * LaunchSignature.anchorFraction - h / 2,
            width: w,
            height: h
        )
        return Layout(rect: rect, transform: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: rect.minX, ty: rect.minY))
    }

    private static func parse(_ d: String) -> Path {
        var path = Path()
        var command: Character = " "
        var nums: [CGFloat] = []
        var token = ""

        func takeToken() {
            if !token.isEmpty, let v = Double(token) { nums.append(CGFloat(v)) }
            token = ""
        }
        func emit() {
            switch command {
            case "M" where nums.count >= 2:
                path.move(to: CGPoint(x: nums[0], y: nums[1]))
            case "L" where nums.count >= 2:
                path.addLine(to: CGPoint(x: nums[0], y: nums[1]))
            case "Q" where nums.count >= 4:
                path.addQuadCurve(to: CGPoint(x: nums[2], y: nums[3]), control: CGPoint(x: nums[0], y: nums[1]))
            case "C" where nums.count >= 6:
                path.addCurve(
                    to: CGPoint(x: nums[4], y: nums[5]),
                    control1: CGPoint(x: nums[0], y: nums[1]),
                    control2: CGPoint(x: nums[2], y: nums[3])
                )
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            nums.removeAll(keepingCapacity: true)
        }

        for ch in d {
            if ch.isLetter {
                takeToken()
                emit()
                command = ch
            } else if ch == " " {
                takeToken()
            } else if ch == "-" {
                takeToken()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        takeToken()
        emit()
        return path
    }
}

// MARK: - 绘制

private struct Signature {
    let theme: EchoTheme
    let size: CGSize
    /// 登录页借这枚签名时不要竖纹和星点，那边有自己的雾。
    var backdrop = true

    private var palette: EchoPalette { theme.palette }
    private var isDark: Bool { theme == .harbor }
    private var rose: Color { isDark ? Color(hex: 0xE98BA6) : Color(hex: 0xC8455F) }

    func draw(into context: GraphicsContext, t: Double) {
        if backdrop {
            drawTexture(context)
            if isDark { drawSpecks(context, t: t) }
        }

        let layout = Mark.layout(in: size)
        let sweep = easeInOut(ramp(t, Beat.sweep))
        if sweep > 0 {
            // 一扫：墨迹从左往右露出来，边上跟一团淡光
            let edge = layout.rect.minX + layout.rect.width * CGFloat(sweep)
            var ink = context
            ink.clip(to: Path(CGRect(x: 0, y: 0, width: edge + 6, height: size.height)))
            ink.fill(Mark.path.applying(layout.transform), with: .color(palette.text))

            if sweep < 1 {
                let r: CGFloat = 26
                let center = CGPoint(x: edge, y: layout.rect.midY)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(
                        Gradient(colors: [
                            isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.08),
                            Color.clear
                        ]),
                        center: center, startRadius: 0, endRadius: r
                    )
                )
            }
        }

        drawHeart(context, t: t, rect: layout.rect)
    }

    /// i 上的那颗心
    private func drawHeart(_ context: GraphicsContext, t: Double, rect: CGRect) {
        let p = ramp(t, Beat.heart)
        guard p > 0 else { return }
        let e = easeOutBack(p)
        let x = rect.minX + rect.width * Mark.heartAt.x
        let y = rect.minY + rect.height * Mark.heartAt.y - CGFloat(1 - e) * 5.5
        let w = Mark.heartWidth * CGFloat(0.35 + 0.65 * e)
        let alpha = min(1, p * 2.6)

        let halo = w * 2.2
        context.fill(
            Path(ellipseIn: CGRect(x: x - halo, y: y - halo, width: halo * 2, height: halo * 2)),
            with: .radialGradient(
                Gradient(colors: [rose.opacity(0.22 * alpha), rose.opacity(0)]),
                center: CGPoint(x: x, y: y), startRadius: 0, endRadius: halo
            )
        )
        context.fill(heartPath(center: CGPoint(x: x, y: y), width: w), with: .color(rose.opacity(alpha)))
    }

    private func heartPath(center c: CGPoint, width: CGFloat) -> Path {
        let r = width / 2, h = width * 0.9
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y + h * 0.42))
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y - h * 0.20),
            control1: CGPoint(x: c.x - r * 1.38, y: c.y - h * 0.06),
            control2: CGPoint(x: c.x - r * 0.88, y: c.y - h * 0.66)
        )
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y + h * 0.42),
            control1: CGPoint(x: c.x + r * 0.88, y: c.y - h * 0.66),
            control2: CGPoint(x: c.x + r * 1.38, y: c.y - h * 0.06)
        )
        path.closeSubpath()
        return path
    }

    // MARK: 背景

    /// graphite：极淡的竖纹，每 3pt 一条，合成一个 Path 一次 stroke 画完。
    private func drawTexture(_ context: GraphicsContext) {
        var path = Path()
        var x: Double = 0
        while x < Double(size.width) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: Double(size.height)))
            x += 3
        }
        context.stroke(
            path,
            with: .color(isDark ? Color.white.opacity(0.012) : Color.black.opacity(0.009)),
            lineWidth: 1
        )
    }

    private func drawSpecks(_ context: GraphicsContext, t: Double) {
        for s in Decor.specks {
            let x = s.x * Double(size.width)
            let y = s.y * Double(size.height)
            let a = s.opacity * (0.55 + 0.45 * sin(t * 1.4 + x))
            context.fill(
                Path(ellipseIn: CGRect(x: x - s.r, y: y - s.r, width: s.r * 2, height: s.r * 2)),
                with: .color(.white.opacity(a))
            )
        }
    }
}

// MARK: - 夜港的星点（固定种子，每次启动一致）

private struct Speck {
    let x, y, r, opacity: Double
}

private enum Decor {
    static let specks: [Speck] = {
        var n = Noise(31_415_926)
        return (0..<80).map { _ in
            Speck(x: n.next(), y: n.next() * 0.72, r: n.next() * 0.9 + 0.25,
                  opacity: 0.12 + n.next() * 0.45)
        }
    }()
}

private struct Noise {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}
