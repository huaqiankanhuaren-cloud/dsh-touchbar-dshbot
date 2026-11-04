#!/bin/bash
# DSHTouchBar 安装脚本
# 把数据脚本、原生 App、DSH 插件安装到正确位置。
# 用法: ./install.sh
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

echo "==> 1. 构建原生 App"
./build.sh

echo "==> 2. 安装数据脚本到 ~/bin"
mkdir -p "$HOME/bin"
cp scripts/dsh-active-bots-json.sh "$HOME/bin/dsh-active-bots-json.sh"
chmod +x "$HOME/bin/dsh-active-bots-json.sh"

echo "==> 3. 安装原生 App 到 $DSH_HOME/ds-touchbar"
mkdir -p "$DSH_HOME/ds-touchbar"
rm -rf "$DSH_HOME/ds-touchbar/DSHTouchBar.app"
cp -R DSHTouchBar.app "$DSH_HOME/ds-touchbar/DSHTouchBar.app"

echo "==> 4. 安装 DSH 插件到 $DSH_HOME/local-plugins/ds-touchbar"
mkdir -p "$DSH_HOME/local-plugins"
rm -rf "$DSH_HOME/local-plugins/ds-touchbar"
cp -R plugin "$DSH_HOME/local-plugins/ds-touchbar"

echo "==> 5. 注册插件到 DSH profile"
PROFILE="$DSH_HOME/profiles/desktop"
if [ -f "$PROFILE/package.json" ]; then
  node -e '
    const fs=require("fs"),p=process.argv[1],link=process.argv[2];
    const d=JSON.parse(fs.readFileSync(p,"utf8"));
    d.dependencies=d.dependencies||{};
    d.dependencies["ds-touchbar"]="link:"+link;
    d.dsh=d.dsh||{}; d.dsh.profile=d.dsh.profile||{}; d.dsh.profile.bundles=d.dsh.profile.bundles||[];
    if(!d.dsh.profile.bundles.includes("ds-touchbar")) d.dsh.profile.bundles.push("ds-touchbar");
    fs.writeFileSync(p, JSON.stringify(d,null,2));
    console.log("  已写入 profile package.json");
  ' "$PROFILE/package.json" "$DSH_HOME/local-plugins/ds-touchbar"
  ln -sf "../../../local-plugins/ds-touchbar" "$PROFILE/node_modules/ds-touchbar" 2>/dev/null || true
else
  echo "  ⚠️ 未找到 $PROFILE/package.json，请手动注册插件"
fi

echo ""
echo "✅ 安装完成。重启 DSH 后生效（插件会在 DSH 启动时拉起 App）。"
echo "   如无 Touch Bar 硬件，App 会自动退出。"
