# CSV Import Contract

## Input

```csv
课程名称,星期,开始节数,结束节数,老师,地点,周数
高等数学,1,1,2,小明,逸夫楼201,1-5、7-11单、12-16双
线性代数,2,3,4,小红,理工楼110,1-16
大学英语,2,3,4,小红,文成楼125,2、5、8
```

## Supported Week Syntax

支持：

```text
1-16
1-5
2、5、8
1-5、7-11单、12-16双
```

奇偶：

```text
单 -> odd
双 -> even
```

兼容：

```text
、
，
,
空格
```

## Parser Model

解析成结构化 week segments：

```json
[
  {"start":1,"end":5,"parity":"all"},
  {"start":7,"end":11,"parity":"odd"},
  {"start":12,"end":16,"parity":"even"}
]
```

最终可以展开成具体 week set，但数据库不必须保存全部实例。

## Preview

导入必须：

```text
Upload
 -> Parse
 -> Validate
 -> Preview
 -> User confirms
 -> Commit
```

## Validation

检查：

- weekday 1-7
- period start/end
- start <= end
- week number 在学期范围
- 空课程名称
- 非法周规则
- 课程时间冲突

## Errors

必须包含：

```text
line
field
code
message
```

## 连堂课

例如：

```text
startPeriod = 1
endPeriod = 3
```

表示一个连续 CourseMeeting。

UI 可以根据设置合并显示，不要拆成三个课程。
