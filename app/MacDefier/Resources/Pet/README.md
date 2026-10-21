# 宠物包格式（用户导入）

用户可在 **设置 → Mr. Defier 宠物 → 导入 zip** 添加自定义宠物。

## 产品原则

| 位置 | 形象 |
|------|------|
| 窗内浮动宠 / 收起条 | 自定义包（可动画） |
| 对话页标题 / 气泡 | 固定 **Mr. Defier** 内置助手 |

导入包只换「窗宠」，不替换助手身份。

## 内置示例包

- `Resources/Pet/Samples/defier-guard-bot.zip`  
  **守卫机器人**（CC0，OpenGameArt *The Robot - Free Sprite*）  
  白金小机器人，idle/跑/警觉/跳/扫视动画，气质偏守护助手，契合 MacDefier。

## zip 结构

```
my-pet.zip
├── pet.json
└── spritesheet.png
```

## pet.json 要点

- `columns` / `rows` / `frameWidth` / `frameHeight`
- `animations.<mood>`：`start`+`count`+`fps` 或 `frames` 数组
- 六态：idle / talk / alert / happy / sleep / scan

存储：`~/Library/Application Support/MacDefier/PetPacks/<id>/`
