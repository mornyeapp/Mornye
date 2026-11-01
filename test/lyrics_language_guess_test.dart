import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lyrics_language_guess.dart';

const _english = [
  'I walk the empty streets when the night is falling down',
  "You told me that you'd stay but now I'm all alone",
  "And I don't know what to do with all this love I've got",
  'We were never meant to be just a story in the dark',
  "It's the only thing I want, the only thing I need",
  'So hold me close tonight and tell me you will stay',
];

const _indonesian = [
  'Aku masih di sini menunggu kau kembali',
  'Walau hati ini tak pernah bisa lupa',
  'Semua yang kita punya hanya tinggal cerita',
  'Jangan pergi dari aku, kau yang selalu ada',
  'Bila malam datang aku ingin kau di sini',
  'Karena cinta ini tidak akan pernah mati',
];

const _spanish = [
  'Yo sé que no hay nadie como tú en mi vida',
  'Cuando el sol se va y la noche llega',
  'Tengo el corazón roto pero sigo aquí',
  'Quiero estar contigo, y ya no puedo más',
  'Soy el que te espera donde el mar termina',
  'Pero los días pasan y las horas también',
];

void main() {
  test('Latin-script lyrics are told apart by their common words', () {
    expect(guessLyricsLanguage(_english), 'en');
    expect(guessLyricsLanguage(_indonesian), 'id');
    expect(guessLyricsLanguage(_spanish), 'es');
  });

  test('a script only one language writes names it', () {
    expect(
      guessLyricsLanguage([
        '夜空に浮かぶ星を見上げて',
        'あなたのことを思い出していた',
        '風が吹いて花びらが舞う',
        'もう一度だけ会いたいと願った',
        '遠い街の灯りが揺れている',
      ]),
      'ja',
    );
    expect(
      guessLyricsLanguage([
        '너를 처음 만난 그날 밤을 기억해',
        '별빛 아래서 우리는 함께 걸었지',
        '시간이 흘러도 나는 여기 있을게',
        '다시 한번 너의 이름을 불러본다',
      ]),
      'ko',
    );
  });

  test('shared scripts answer only from telling letters', () {
    expect(
      guessLyricsLanguage([
        'Мы были молоды и верили в мечты',
        'Ты помнишь этот вечер у реки',
        'Ветер уносит наши лёгкие шаги',
        'Я всё ещё жду тебя здесь',
      ]),
      'ru',
    );
    expect(
      guessLyricsLanguage([
        'Ми були молоді і вірили у мрії',
        'Ти пам’ятаєш цей вечір біля річки',
        'Вітер несе наші легкі кроки',
        'Я все ще чекаю тебе тут і є надія',
      ]),
      'uk',
    );
    expect(
      guessLyricsLanguage([
        '我们在这里说过的话',
        '时间会过去还有你的爱',
        '让风带走我们的梦',
        '开始的时候没有人知道',
        '这条路我们一起走过',
        '为什么你说要离开',
      ]),
      'zh-Hans',
    );
  });

  test('short, mixed or unclear lyrics give no answer', () {
    expect(guessLyricsLanguage(['Hello there']), isNull);
    expect(
      guessLyricsLanguage([
        '너를 처음 만난 그날 밤을 기억해',
        "Baby I don't know what to do without you tonight",
        'Hold me close and never let me go away from here',
        '별빛 아래서 우리는 함께 걸었지',
      ]),
      isNull,
    );
    expect(
      guessLyricsLanguage([
        'Kimi no namae wo yonda yoru ni',
        'Hoshi ga furu sora no shita de',
        'Mou ichido dake aitakute',
        'Tooku no machi no akari ga yureteiru',
      ]),
      isNull,
    );
  });

  test('a target matches the guess by its base language', () {
    expect(lyricsAlreadyIn(_english, 'en'), isTrue);
    expect(lyricsAlreadyIn(_english, 'id'), isFalse);
    expect(lyricsAlreadyIn(_spanish, 'es-419'), isTrue);
    expect(lyricsAlreadyIn(['Hello there'], 'en'), isFalse);
  });
}
