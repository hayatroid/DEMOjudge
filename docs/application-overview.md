# 💻 Application Overview

DEMOjudge はデモ用のオンラインジャッジである．通常の機能に加えて，ある種の耐障害性をもつ．

- ユーザは
  - ソースコードを提出できる (entry)
  - ジャッジの進捗を見られる (phases)
  - ジャッジのログを見られる (events)
  - 順位表を見られる (views)

さらに，

- ジャッジは
  - 提出に判定を与えられる
  - 提出に判定を与えられないとしてエスカレーションできる
- 管理者は
  - エスカレーションされた提出を解決できる
  - エスカレーションされた提出を見られる (views)

## DEMO

### alice の提出が AC を得た

alice が $a, b$ を受け取り $a + b$ を返すプログラムを提出し，AC を得た．
views > standings の alice の solved が 1 増えた．

|              entry               |              phases               |              events               |              views               |
| :------------------------------: | :-------------------------------: | :-------------------------------: | :------------------------------: |
| ![](assets/alice-a-1-entry.webp) | ![](assets/alice-a-1-phases.webp) | ![](assets/alice-a-1-events.webp) | ![](assets/alice-a-1-views.webp) |

### bob の提出が WA を得た

bob が誤って $a - b$ を返すプログラムを提出し，WA を得た．
views > standings の bob の penalty が 1 増えた．

|             entry              |             phases              |             events              |             views              |
| :----------------------------: | :-----------------------------: | :-----------------------------: | :----------------------------: |
| ![](assets/bob-a-1-entry.webp) | ![](assets/bob-a-1-phases.webp) | ![](assets/bob-a-1-events.webp) | ![](assets/bob-a-1-views.webp) |

### bob の提出が CE を得た

bob が誤ってセミコロンを忘れたプログラムを提出し，CE を得た．
phases の遷移が compile error を経由した．
views > standings には影響しなかった．

|             entry              |             phases              |             events              |             views              |
| :----------------------------: | :-----------------------------: | :-----------------------------: | :----------------------------: |
| ![](assets/bob-a-2-entry.webp) | ![](assets/bob-a-2-phases.webp) | ![](assets/bob-a-2-events.webp) | ![](assets/bob-a-2-views.webp) |

### carol の提出がリトライされて AC を得た

carol も $a + b$ を返すプログラムを提出した．
ジャッジ中のノードが故障して他のノードが引き継ぎ，AC を得た．
phases の遷移が queued と compiling 間を 1 往復した．
views > standings の carol の solved が 1 増えた．

|              entry               |              phases               |              events               |              views               |
| :------------------------------: | :-------------------------------: | :-------------------------------: | :------------------------------: |
| ![](assets/carol-a-1-entry.webp) | ![](assets/carol-a-1-phases.webp) | ![](assets/carol-a-1-events.webp) | ![](assets/carol-a-1-views.webp) |

### dave の提出がエスカレーションされた

dave も $a + b$ を返すプログラムを提出した．
ジャッジ中のノードが故障して他のノードが引き継ぐことを 3 回繰り返し，エスカレーションされた．
phases の遷移が queued と compiling 間を 3 往復し，escalated に入った．
views > escalations にも当該提出が入った．

|              entry              |              phases              |              events              |              views              |
| :-----------------------------: | :------------------------------: | :------------------------------: | :-----------------------------: |
| ![](assets/dave-a-1-entry.webp) | ![](assets/dave-a-1-phases.webp) | ![](assets/dave-a-1-events.webp) | ![](assets/dave-a-1-views.webp) |

### dave の提出が解決されて AC を得た

管理者がエスカレーションを解決し，dave の提出は AC を得た．
views > escalations から当該提出が消え，views > standings の dave の solved が 1 増えた．

|              resolve              |                  phases                  |                  events                  |                  views                  |
| :-------------------------------: | :--------------------------------------: | :--------------------------------------: | :-------------------------------------: |
| ![](assets/dave-a-1-resolve.webp) | ![](assets/dave-a-1-resolve-phases.webp) | ![](assets/dave-a-1-resolve-events.webp) | ![](assets/dave-a-1-resolve-views.webp) |
