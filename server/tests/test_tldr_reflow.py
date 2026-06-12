import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tldr_reflow import reflow_tldr  # noqa: E402


class TLDRReflowTests(unittest.TestCase):
    def test_announced_comma_list_reflows(self):
        t = ("Claude presented four path options: dogfooding the dense TL;DR, "
             "re-sourcing clean X/Reddit voice samples for the parked social win, "
             "adding a verbosity dimension to the rubric harness, or moving off "
             "prompts to performance levers.")
        out = reflow_tldr(t)
        self.assertIn("four path options:\n", out)
        self.assertEqual(out.count("\n"), 4)  # lead + 4 items = 4 breaks
        self.assertIn("\ndogfooding the dense TL;DR", out)

    def test_trailing_sentence_peeled_into_own_beat(self):
        t = ("Claude gave three options: rewrite the stack natively in Swift, "
             "build a persistent python worker over stdin, or park the task "
             "entirely. It recommends the worker.")
        out = reflow_tldr(t)
        self.assertIn("park the task entirely", out)
        self.assertTrue(out.rstrip().endswith("It recommends the worker."))
        self.assertIn("\n\nIt recommends the worker.", out)

    def test_parenthetical_labels_left_alone(self):
        # used to mangle: it anchored on the inner "(A:" colon
        t = ("Claude proposed three concrete staged scenarios for your demo "
             "(A: a release-timing judgment, B: a memory reference, C: catching "
             "a bad mock strategy), recommending C.")
        self.assertEqual(reflow_tldr(t), t)

    def test_short_word_list_left_inline(self):
        t = ("Aaron listed three things founders should focus on: building "
             "product, talking to users, and exercising.")
        self.assertEqual(reflow_tldr(t), t)

    def test_two_item_list_left_inline(self):
        t = "The agent shipped two fixes: the pager dot click and the bottom padding."
        self.assertEqual(reflow_tldr(t), t)

    def test_plain_colon_prose_untouched(self):
        t = "Heads up: the date in the draft does not match the thread."
        self.assertEqual(reflow_tldr(t), t)

    def test_no_colon_noop(self):
        t = "The agent shipped two UI fixes and is waiting on your review."
        self.assertEqual(reflow_tldr(t), t)

    def test_already_multiline_beat_untouched(self):
        t = "The agent proposed four options:\n\n1. bump contrast\n\n2. add a rule"
        self.assertEqual(reflow_tldr(t), t)

    def test_empty_and_none_safe(self):
        self.assertEqual(reflow_tldr(""), "")
        self.assertEqual(reflow_tldr("Sarah just asked for the estimate."),
                         "Sarah just asked for the estimate.")


if __name__ == "__main__":
    unittest.main()
