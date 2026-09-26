include $(TOPDIR)/rules.mk

LUCI_TITLE:=Sing 配置与服务管理面板
LUCI_DESCRIPTION:=sing-box配置与服务轻量管理面板
LUCI_DEPENDS:=+luci-base +sing-box +rpcd +jshn +jsonfilter +curl
LUCI_PKGARCH:=all

PKG_LICENSE:=MIT
PKG_NAME:=luci-app-sing
PKG_VERSION:=1.2
PKG_RELEASE:=3

# 允许外部环境变量或 SDK 覆盖版本号
ifneq ($(LUCI_SING_VERSION),)
  PKG_VERSION:=$(LUCI_SING_VERSION)
endif

define Build/Prepare/luci-app-sing
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/rpcd/luci.sing-box \
		$(PKG_BUILD_DIR)/root/usr/libexec/sing-box-panel-worker
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
