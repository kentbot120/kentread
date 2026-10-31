# 转书 zhuanshu.koplugin

KOReader 插件：把正在读的整本书交给大模型，写成一篇浓缩版。读原书时点一下就弹出来看，关掉回到原来那页。

浓缩版的写法取自 [ljg-book](https://github.com/lijigang/ljg-skills/tree/master/skills/ljg-book)：写给没读过原书的人，沿着一条线索讲清书里具体发生了什么、理解怎样被改变，需要时配图（SVG）。

## 流程

1. 取出全书正文，整本一次发给模型（DeepSeek 上下文 1M token，约 100 万字以内的书都装得下）
2. 模型先思考全书结构，再写正文；流式接收，弹窗里先显示思考进度，正文一开始写就能看，图在全文写完后显示
3. 写完存进这本书的 `.sdr/zhuanshu/`

生成时可以关掉弹窗回去看书，转书会在后台写完再提示；关掉这本书或点「停止生成」就停止。

## 安装

1. 把整个目录拷到 Kindle 的 `koreader/plugins/zhuanshu.koplugin/`
2. 把 `config.sample.lua` 复制成 `config.lua`，填 `api_key`（默认 DeepSeek `deepseek-flash`，任何 OpenAI 兼容接口都行）
3. 重启 KOReader

## 使用

- 读书时：菜单 → 工具 → 转书 → 浓缩版（没有就提示生成；生成中打开看进度）
- 绑手势：手势管理里选「转书：浓缩版」
- 弹窗里可以调字号，「钉住」当前页，下次打开跳回去

## 限制

- 只支持 KOReader 能排版的文字书（EPUB、AZW3、MOBI、FB2、TXT 等），不支持 PDF
- 国内网络下 Kindle 连不上 OpenAI / Anthropic / Google
- 中途失败要从头再来，没有断点
- 调试：正文是 `.sdr/zhuanshu/condensed.html`，图是 `fig<i>.svg`

curl 调用的写法参考 [乔木 SimpleUI](https://github.com/joeseesun/qiaomu-simpleui)（GPL-3.0）。
