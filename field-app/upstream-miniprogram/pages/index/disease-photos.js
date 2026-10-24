// 病害详情的实拍对照照片；核验和署名见 docs/symptom-photo-sources.json。
module.exports = [
  {
    id: 'blast', name: '稻瘟病',
    photos: [
      { src: '/assets/symptoms/blast-leaf.jpg', caption: '叶片：两头尖的斑' },
      { src: '/assets/symptoms/blast-neck.jpg', caption: '稻穗下方：细茎变褐' }
    ]
  },
  {
    id: 'brown-spot', name: '褐斑病',
    photos: [
      { src: '/assets/symptoms/brown-spot-close.jpg', caption: '近看：圆形或椭圆形斑' },
      { src: '/assets/symptoms/brown-spot-field.jpg', caption: '整片叶子：褐色小斑点' }
    ]
  },
  {
    id: 'sheath-blight', name: '纹枯病',
    photos: [
      { src: '/assets/symptoms/sheath-blight-waterline.jpg', caption: '茎外层：灰白、褐色斑' },
      { src: '/assets/symptoms/sheath-blight-lesion.jpg', caption: '叶片：大片不规则斑纹' }
    ]
  },
  {
    id: 'bacterial-streak', name: '细菌性条斑病',
    photos: [
      { src: '/assets/symptoms/bacterial-streak-early.jpg', caption: '叶片：细长的条斑' },
      { src: '/assets/symptoms/bacterial-streak-severe.jpg', caption: '严重时：条斑连成片' }
    ]
  },
  {
    id: 'bacterial-blight', name: '细菌性白叶枯病',
    photos: [
      { src: '/assets/symptoms/bacterial-blight-edge.jpg', caption: '叶缘：从边上开始枯黄' },
      { src: '/assets/symptoms/bacterial-blight-severe.jpg', caption: '严重时：大片叶子干枯' }
    ]
  },
  {
    id: 'panicle-blight', name: '细菌性穗枯病',
    photos: [
      { src: '/assets/symptoms/panicle-blight-compare.jpg', caption: '病穗与正常穗对照' },
      { src: '/assets/symptoms/panicle-blight-field.jpg', caption: '近看：部分谷壳变褐' }
    ]
  },
  {
    id: 'downy-mildew', name: '霜霉病',
    photos: [
      { src: '/assets/symptoms/downy-mildew-plant.jpg', caption: '田间：植株发黄、矮小' },
      { src: '/assets/symptoms/downy-mildew-leaf.jpg', caption: '叶片：变宽、发黄' }
    ]
  },
  {
    id: 'dead-heart', name: '枯心症状',
    photos: [
      { src: '/assets/symptoms/dead-heart-symptom.jpg', caption: '中间的新叶枯黄' },
      { src: '/assets/symptoms/dead-heart-bore-hole.jpg', caption: '再查茎上有没有虫孔' }
    ]
  },
  {
    id: 'tungro', name: '东格鲁病毒病',
    photos: [
      { src: '/assets/symptoms/tungro-leaf.jpg', caption: '叶片：黄到黄橙色' },
      { src: '/assets/symptoms/tungro-field.jpg', caption: '田间：成簇发黄、矮小' }
    ]
  }
]
