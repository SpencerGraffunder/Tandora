extends RefCounted

enum PieceType { I, O, T, L, J, S, Z }
enum TileType { IOT = 0, JS = 1, LZ = 2, GRAY = 3, BLANK = -1 }
enum Direction { DOWN, LEFT, RIGHT }
enum Rotation { CW, CCW }
enum MoveAllowance { CANT_PIECE, CANT_BOARD, CAN }
enum TetrisState { SPAWN_DELAY, SPAWN, PLAY, CHECK_CLEAR, CLEAR, DIE, GAME_OVER }

const VISIBLE_ROWS = 20
const BUFFER_ROWS = 2
const TOTAL_ROWS = VISIBLE_ROWS + BUFFER_ROWS
