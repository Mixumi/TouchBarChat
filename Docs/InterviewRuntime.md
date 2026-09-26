# 实时面试链路与边界

TouchBarChat 只处理电脑正在播放的声音。点击“开启面试”时检查屏幕与系统音频录制、所选语言的本地语音识别能力，以及可选的 API 配置；旧版 SFSpeechRecognizer 路径另需语音识别授权。权限、模型不可用或部分填写但无效的 API 设置会阻止启动，完全跳过 API 则进入“仅转写”模式，不会回退到云端识别。真正开始采集后才创建本机面试记录并最小化窗口。每场面试固定使用启动时选定的转写语言与 AI 回答语言；暂停/继续不会中途换模型。暂停或结束时先排空已收到的音频，再等待语音识别的最终结果（新版识别器最多三十秒、旧版最多五秒）；若最终结果未返回，则保留最新的临时文字并提示。暂停后已提交给 AI 的回答可以继续完成；结束会取消未完成请求、保存记录并打开主窗口。

## 一题怎样确认

1. ScreenCaptureKit 提供系统音频 PCM；Apple SoundAnalysis 在本机提供“是否有人声”的辅助证据，失败时降级到已有的 PCM 能量判断。它们都不能判断说话人身份。
2. Apple Speech 先发布会回改的 partial 转写。`isFinal` 仅对当前识别任务有效，不能单独代表面试官说完。
   音频从 ScreenCaptureKit 的串行采样队列按顺序送到主线程；启动阶段的音频也交给识别器，暂停/结束时等待队列排空并调用 `endAudio()`，避免丢弃最后一批 PCM 与迟到的最终文字。
3. 只有文字像问题或面试指令、文字稳定至少 0.7 秒、播放音频持续安静至少 1.6 秒（显然未完的句尾等 3 秒），再经过 0.45 秒可撤销确认，才提交候选。系统停止送静音 PCM 时，用更长的无包间隔兜底。新出现的持续声音或继续说话会撤销候选；短促通知音不会把确认计时反复清零。持续背景声下，用更长的文字稳定窗口兜底。
4. 配置 API 时，同一次回答请求可返回严格的“等待补充”标记；此时保留转录并继续观察。相同问题若再经过至少 5 秒的安静确认，会自动发起一次不带这层判断的回答请求；新声音重计安静时间，新转写则取消旧快照。连续无法确认时有 30 秒绝对上限，菜单栏提示“手动生成当前回答”，不会静默无限等待。
5. 新语音、实质性转写变化、结束操作和请求代际标识共同避免迟到回答覆盖当前题；暂停只停采集，不取消已提交的回答。单纯补空格或标点不应取消已发送的请求。已提交的题与下一题分开记录，无法完成的回答保留为无回答状态。

## 需要回放的真实场景

- 面试官一句话中间停顿两秒，然后补充要求；不应把半句永久当成完整问题。
- 面试官先介绍自己的团队、说“好的”，或电脑播放通知音；不应生成回答。
- 面试官问完一句短追问“为什么？”；应能利用近期问答草稿理解上下文。
- Apple Speech 在一句话结束后回改旧字、补标点，或在旧版识别任务轮换时延迟最终结果；旧版约 35 秒后优先在安静处轮换，连续说话时约 52 秒强制轮换，不应重复旧题或停住后续转写。新版 SpeechTranscriber 为长流识别，不按此计时轮换。
- 同一段话在中、英、韩、日、俄、法、葡语中的问句/指令与承接词不同；启发式按转写语言选择，AI 回答可独立指定语言。自动化测试覆盖常见文本案例，不等于七种语言的真实会议音频已验证。
- AI 正在生成时对方继续说、用户暂停/继续/结束，或迟到的网络响应返回；只允许当前有效版本更新 Touch Bar 和记录。
- 未配置 API、API 失败、本机人声分类不可用、无 Touch Bar、保存记录失败；转写记录应尽可能保留，并清楚提示降级或错误。

这里的阈值是保守初值，不是准确率承诺。代码测试覆盖文字边界、短追问、常见误触发、API 等待标记、记录写盘与恢复；仍需要在带 Touch Bar 的机器上用经参与者同意的会议音频做回放验证。

参考：[Apple Speech 结果](https://developer.apple.com/documentation/speech/sfspeechrecognitionresult)、[Apple SoundAnalysis](https://developer.apple.com/documentation/soundanalysis/classifying-sounds-in-an-audio-stream)、[LiveKit 回合检测](https://docs.livekit.io/agents/logic/turns/turn-detector/)、[interview-copilot](https://github.com/ericwang915/interview-copilot/blob/main/src/renderer/app.js)、[live_interview_agent 完句判断](https://github.com/justQrius/live_interview_agent/blob/master/sidecar/src/classification/completeness_detector.py)。
