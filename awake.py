import time as t
import random as r
import pyautogui as p

class Monitor:
  def __init__(self, x_min, x_max, y_min, y_max):
    self.x_min = x_min
    self.x_max = x_max
    self.y_min = y_min
    self.y_max = y_max

# pyautogui does not support multiple monitors.
# p.size() will output dimensions of monitor 1.
# Get dimensions of other monitors by printing the output of p.position() while the mouse is in each corner of each monitor.
MONITORS = {
  1: Monitor(0, p.size()[0] - 1, 0, p.size()[1] - 1),
  2: Monitor(-1080, 0, -228, 1691)
}

def identify_monitor(x, y):
  for monitorDef in MONITORS.items():
    monitor = monitorDef[1]
    if x >= monitor.x_min and x <= monitor.x_max and y >= monitor.y_min and y <= monitor.y_max:
      return monitorDef[0]
  return 0

def append_if_valid(moves, x, y):
  if identify_monitor(x, y) > 0:
    moves.append((x, y))
  return moves

def valid_moves(x, y):
  moves = []
  append_if_valid(moves, x + 1, y)
  append_if_valid(moves, x + 1, y + 1)
  append_if_valid(moves, x + 1, y - 1)
  append_if_valid(moves, x - 1, y)
  append_if_valid(moves, x - 1, y + 1)
  append_if_valid(moves, x - 1, y - 1)
  append_if_valid(moves, x, y + 1)
  append_if_valid(moves, x, y - 1)
  return moves

p.FAILSAFE = False

while True:
  x, y = p.position()

  potential_moves = valid_moves(x, y)
  move = (0, 0)
  if len(potential_moves) > 0:
    move_id = r.randint(0, len(potential_moves) - 1)
    move = potential_moves[move_id]

  # print('current: ' + str(x) + ', ' + str(y))
  # print('potential moves: ' + str(potential_moves))
  print('next: ' + str(move[0]) + ', ' + str(move[1]))

  p.moveTo(move[0], move[1])

  # time between moves is in seconds
  t.sleep(599)
